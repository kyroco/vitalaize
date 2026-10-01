defmodule Wallboard.Link.Server do
  @moduledoc """
  The hub's end of one collector's stream (see `Wallboard.Link`).

  Each stream runs in its own process. It asks `Wallboard.Link.Hub` who the
  certificate belongs to, then reads messages until the collector goes: the
  first must be a `Hello`, answered with `Resume`; every event after it is
  saved under the certificate's machine and confirmed with `Stored`.

  It reads the stream's bytes itself instead of taking the gRPC library's
  ready-made list of messages, because that list has no size limit: it
  would gather a message of any length a collector announced.
  """

  # Only the one message format: no JSON, no gRPC-Web, no compression.
  use GRPC.Server,
    service: Wallboard.Collector.Proto.Collector.Service,
    codecs: [GRPC.Codec.Proto],
    compressors: [],
    http_transcode: false

  require Logger

  alias GRPC.Server.Adapters.Cowboy
  alias Wallboard.Collector.Proto
  alias Wallboard.Link.{Authority, Hub}
  alias Wallboard.Store

  @resume_chunk 1_000
  @max_items 256

  @doc false
  # Called by the gRPC library for each Stream call. Its own list of
  # messages is never read.
  def stream(_messages, stream) do
    counter = :atomics.new(1, [])

    cert = Cowboy.get_cert(stream.payload)

    case Hub.attach(cert, stream, counter) do
      {:ok, machine, limits, dir} ->
        now = System.monotonic_time(:millisecond)

        loop(%{
          cert: cert,
          dir: dir,
          checked: now,
          machine: machine,
          stream: stream,
          counter: counter,
          limits: limits,
          rest: "",
          hello?: false,
          seq: 0,
          at: now
        })

      {:error, _} ->
        raise GRPC.RPCError, status: :unauthenticated, message: "this machine is not approved"
    end
  end

  @doc """
  Sends one message to a collector. `counter` gives the message its id, so
  the stream's own process and the hub can both send.
  """
  def send_to(stream, counter, body) do
    id = :atomics.add_get(counter, 1, 1)
    GRPC.Server.send_reply(stream, %Proto.FromHub{id: id, body: body})
    :ok
  end

  defp loop(s) do
    {fin?, data} =
      case Cowboy.Handler.read_body(s.stream.payload.pid) do
        {:more, data} -> {false, data}
        {:ok, data} -> {true, data}
      end

    {frames, rest} = split(s.rest <> data, s.limits.max_message_bytes, [])
    s = s |> still_approved() |> spend(length(frames), byte_size(data))
    s = frames |> Enum.map(&decode/1) |> handle(%{s | rest: rest})

    cond do
      not fin? -> loop(s)
      rest == "" -> :ok
      true -> refuse(:invalid_argument, "the stream ended in the middle of a message")
    end
  end

  # A certificate can be revoked from outside the hub's own program (the
  # `mix` task that replaces one does it), so an open stream looks its own
  # up again now and then. A collector speaks at least every 20 seconds, so
  # a revoked one is cut off within that.
  defp still_approved(s) do
    now = System.monotonic_time(:millisecond)

    if now - s.checked < s.limits.recheck_ms do
      s
    else
      case Authority.machine(s.dir, s.cert) do
        {:ok, machine} when machine == s.machine ->
          %{s | checked: now}

        # The list could not be read just now (a busy disk, too many open
        # files). That is no verdict: keep the stream and look again.
        {:error, :unreadable} ->
          %{s | checked: now}

        # Revoked: told so, and it stops for good.
        {:error, :revoked} ->
          send_to(s.stream, s.counter, {:disconnected, %Proto.Disconnected{}})
          refuse(:unauthenticated, "this machine is no longer approved")

        # Not on the list at all. The stream ends, and the handshake decides
        # when it tries again.
        _ ->
          refuse(:unauthenticated, "this machine is not approved")
      end
    end
  end

  # gRPC puts five bytes before each message: whether it is compressed, and
  # its length. A length over the limit is refused before the message is
  # gathered.
  defp split(<<0, size::32, _::binary>>, max, _acc) when size > max,
    do: refuse(:resource_exhausted, "a message of #{size} bytes is over the limit of #{max}")

  defp split(<<0, size::32, frame::binary-size(size), rest::binary>>, max, acc),
    do: split(rest, max, [frame | acc])

  defp split(<<flag, _::binary>>, _max, _acc) when flag != 0,
    do: refuse(:unimplemented, "compressed messages are not accepted")

  defp split(rest, _max, acc), do: {Enum.reverse(acc), rest}

  defp decode(frame) do
    Proto.FromCollector.decode(frame)
  rescue
    _ -> refuse(:invalid_argument, "a message could not be read")
  end

  # Two buckets that refill with time, one of messages and one of bytes. A
  # collector that empties either is cut off; its events stay in its own
  # buffer and it tries again after a wait. The buckets belong to the
  # machine, not the stream (the hub keeps them), so connecting again does
  # not fill them.
  defp spend(s, messages, bytes) do
    now = System.monotonic_time(:millisecond)
    l = s.limits
    {had_m, had_b, at} = Hub.bucket(s.machine, l, now)
    secs = max(now - at, 0) / 1000
    have_m = min(l.message_burst * 1.0, had_m + secs * l.messages_per_second) - messages
    have_b = min(l.byte_burst * 1.0, had_b + secs * l.bytes_per_second) - bytes
    # Never below empty: a cut-off machine earns its way back at the
    # usual rate, however much it tried to send.
    Hub.put_bucket(s.machine, {max(have_m, 0.0), max(have_b, 0.0), now})

    if have_m < 0 or have_b < 0 do
      Logger.warning("Link: #{s.machine} sent too much too fast; its stream is closed.")
      refuse(:resource_exhausted, "too many messages too fast")
    end

    %{s | at: now}
  end

  defp handle([], s), do: s

  defp handle([%Proto.FromCollector{body: {:hello, hello}} | rest], %{hello?: false} = s) do
    info = %{label: hello.machine, os: hello.os, version: hello.version, folders: hello.folders}
    Store.put_collector_machine(s.machine, info, System.os_time(:second))
    Hub.hello(s.machine, info)
    resume(s)
    handle(rest, %{s | hello?: true})
  end

  defp handle(_messages, %{hello?: false}),
    do: refuse(:failed_precondition, "the first message must be a hello")

  defp handle(messages, s) do
    {events, seq, alive?} =
      Enum.reduce(messages, {[], s.seq, false}, fn m, {events, seq, alive?} ->
        case m.body do
          {:event, event} -> {[event | events], max(seq, m.seq), alive?}
          {:ack, %Proto.Ack{id: 0}} -> {events, seq, true}
          _ -> {events, seq, alive?}
        end
      end)

    rows = events |> Enum.reverse() |> Enum.flat_map(&row/1)

    if rows != [] do
      # The database tells the rest of the board what it saved (see
      # `Wallboard.Store.put_collector_events/3`).
      if Store.put_collector_events(s.machine, rows, System.os_time(:second)) != :ok,
        do: refuse(:unavailable, "the hub could not save; try again")
    end

    # A collector that only says it is alive still gets an answer, so it can
    # tell a quiet hub from a dead one.
    if events != [] or alive?,
      do: send_to(s.stream, s.counter, {:stored, %Proto.Stored{seq: seq}})

    %{s | seq: seq}
  end

  defp resume(s) do
    l = s.limits
    since = System.os_time(:second) - l.resume_days * 86_400

    chunks =
      s.machine
      |> Store.collector_positions(since, l.resume_points)
      |> Enum.map(
        &%Proto.ResumePoint{session_id: &1.session_id, file: &1.file, position: &1.position}
      )
      |> Enum.chunk_every(@resume_chunk)

    chunks = if chunks == [], do: [[]], else: chunks
    last = length(chunks) - 1

    chunks
    |> Enum.with_index()
    |> Enum.each(fn {points, i} ->
      send_to(s.stream, s.counter, {:resume, %Proto.Resume{points: points, more: i < last}})
    end)
  end

  # An event the filter could not have built is dropped, and still counts as
  # received, so the collector does not send it for ever.
  defp row(%Proto.Event{} = e) do
    if e.session_id =~ ~r/\A[A-Za-z0-9_-]{1,100}\z/ and byte_size(e.file) <= 1024 and
         String.valid?(e.file) and length(e.items) <= @max_items do
      [
        %{
          session_id: e.session_id,
          file: e.file,
          position: e.position,
          at: e.at,
          kind: kind(e),
          event: Proto.Event.encode(e)
        }
      ]
    else
      []
    end
  end

  defp kind(%Proto.Event{file: file}) when file != "", do: "file"

  defp kind(%Proto.Event{items: items}) do
    if Enum.any?(items, &match?(%Proto.Item{body: {:ended, _}}, &1)), do: "end", else: "status"
  end

  defp refuse(status, message), do: raise(GRPC.RPCError, status: status, message: message)
end

defmodule Wallboard.Link.Endpoint do
  @moduledoc false
  use GRPC.Endpoint

  run(Wallboard.Link.Server)
end
