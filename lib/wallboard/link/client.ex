defmodule Wallboard.Link.Client do
  @moduledoc """
  The collector's side of the link (see `Wallboard.Link`): one stream to
  the hub, kept open, with everything unsent held in a buffer on disk.

      {Wallboard.Link.Client,
       host: "192.168.1.20", port: 4748,
       tls: %{cert_pem: ..., key_pem: ..., ca_pem: ...},
       hello: Wallboard.Collector.Filter.hello(...),
       buffer: "/path/to/link.buffer",
       listener: pid}

  `push/2` takes an event from `Wallboard.Collector.Filter` and returns
  once it is on disk. From there the client sends it, keeps it until the
  hub confirms it, and sends it again after a dropout if it must.

  The `listener`, when given, gets `{:wallboard_link, what}` messages:

    * `:up`: the stream is open
    * `{:resume, points}`: the hub's position in each session file, as
      `%{{session_id, file} => position}`. Whoever reads the session files
      sends what lies past these; the buffer has already dropped the rest.
    * `{:stored, seq}`: the hub saved everything up to this seq
    * `:back_soon`: the hub is restarting on purpose
    * `{:down, wait_ms}`: the stream is gone; the next try is in `wait_ms`
    * `:removed`: the hub revoked this machine; the client has stopped

  ## Pace

  The client sends at most 50 events every 100 ms, and never has more than
  200 waiting for the hub's confirmation, which keeps it far under the
  hub's limits (`Wallboard.Link.limits/0`). Every 20 seconds it tells the
  hub it is alive, and it gives a hub that has said nothing for a minute
  up for gone.
  """

  use GenServer
  require Logger

  alias GRPC.Client.Adapters.Mint, as: Adapter
  alias Wallboard.Collector.Proto
  alias Wallboard.Link.{Authority, Backoff, Buffer}

  @defaults %{
    tick_ms: 100,
    per_tick: 50,
    bytes_per_tick: 100_000,
    window: 200,
    keepalive_ms: 20_000,
    silence_ms: 60_000,
    settle_ms: 10_000,
    connect_ms: 10_000
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Queues an event, or a list of them, for the hub. They are on disk when
  this returns. A list costs one write to the disk, not one each, so pass
  the events of many lines together.
  """
  def push(client \\ __MODULE__, events)

  def push(client, %Proto.Event{} = event), do: push(client, [event])

  def push(client, events) when is_list(events),
    do: GenServer.call(client, {:push, events}, 30_000)

  @doc "The pace the client keeps unless told otherwise."
  def pace, do: @defaults

  @doc "Where the client stands: its `phase`, how many events `waiting`, their `bytes`."
  def status(client \\ __MODULE__), do: GenServer.call(client, :status)

  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    tls = Authority.collector_tls(Keyword.fetch!(opts, :tls))

    # The gRPC library logs an error and a "retrying" warning of its own for
    # every try that fails, though it is this module that retries. One calm
    # line per try, from `down/2`, is enough.
    Logger.put_module_level(GRPC.Client.Connection, :error)
    Logger.put_module_level(GRPC.Client.Adapters.Mint.ConnectionProcess, :none)

    s = %{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.fetch!(opts, :port),
      tls: tls,
      hello: Keyword.fetch!(opts, :hello),
      listener: opts[:listener],
      buffer: Buffer.open(Keyword.fetch!(opts, :buffer), Keyword.take(opts, [:max_bytes])),
      backoff: Backoff.new(opts[:backoff] || []),
      pace: Map.merge(@defaults, Map.new(opts[:pace] || %{})),
      # :waiting, :connecting, :resuming, :live or :removed
      phase: :waiting,
      conn: nil,
      points: %{},
      sent: 0,
      in_flight: 0,
      heard: 0,
      back_soon: false,
      pump: nil
    }

    send(self(), :connect)
    {:ok, s}
  end

  @impl true
  def handle_call({:push, events}, _from, s) do
    buffer = Buffer.push(s.buffer, events)
    {shed?, buffer} = Buffer.take_shed(buffer)
    s = %{s | buffer: buffer}

    # Shed events must be read from their files again, and only a new
    # stream brings the Resume that says from where.
    s =
      if shed? and s.phase in [:resuming, :live] do
        Logger.warning("Link: the buffer is full; older events will be read again from disk.")
        down(s, :shed)
      else
        pump(s)
      end

    {:reply, :ok, s}
  end

  def handle_call(:status, _from, s) do
    {waiting, bytes} = Buffer.size(s.buffer)
    {:reply, %{phase: s.phase, waiting: waiting, bytes: bytes}, s}
  end

  @impl true
  def handle_info(:connect, %{phase: :waiting} = s) do
    ref = make_ref()
    parent = self()
    target = {s.host, s.port, s.tls, s.hello, s.pace.connect_ms, ref}
    {pid, mon} = spawn_monitor(fn -> session(parent, ref, target) end)

    {:noreply,
     %{s | phase: :connecting, conn: %{ref: ref, pid: pid, mon: mon, stream: nil, channel: nil}}}
  end

  def handle_info({:link_up, ref, channel, stream}, %{conn: %{ref: ref}} = s) do
    notify(s, :up)
    conn = %{s.conn | channel: channel, stream: stream}
    Process.send_after(self(), {:keepalive, ref}, s.pace.keepalive_ms)
    Process.send_after(self(), {:settled, ref}, s.pace.settle_ms)

    {:noreply,
     %{s | phase: :resuming, conn: conn, points: %{}, sent: 0, in_flight: 0, heard: now()}}
  end

  def handle_info({:link_message, ref, %Proto.FromHub{} = message}, %{conn: %{ref: ref}} = s) do
    s = %{s | heard: now()}
    {:noreply, hub(message.body, ack(s, message.id))}
  end

  def handle_info({:link_down, ref, reason}, %{conn: %{ref: ref}} = s),
    do: {:noreply, down(s, reason)}

  def handle_info({:DOWN, mon, :process, _, reason}, %{conn: %{mon: mon}} = s),
    do: {:noreply, down(s, reason)}

  def handle_info({:keepalive, ref}, %{conn: %{ref: ref}} = s) do
    if now() - s.heard > s.pace.silence_ms do
      {:noreply, down(s, :silent)}
    else
      Process.send_after(self(), {:keepalive, ref}, s.pace.keepalive_ms)
      {:noreply, transmit(s, %Proto.FromCollector{body: {:ack, %Proto.Ack{id: 0}}})}
    end
  end

  # The stream has held for a while: the hub is really back, so the next
  # dropout starts from the short wait again.
  def handle_info({:settled, ref}, %{conn: %{ref: ref}} = s),
    do: {:noreply, %{s | backoff: Backoff.reset(s.backoff)}}

  def handle_info(:pump, s), do: {:noreply, pump(%{s | pump: nil})}

  # Late messages from a stream that is already gone.
  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    hang_up(s)
    Buffer.close(s.buffer)
  end

  # ---------------------------------------------------------------------------
  # What the hub says

  defp hub({:resume, %Proto.Resume{points: points, more: more}}, %{phase: :resuming} = s) do
    points =
      Enum.reduce(points, s.points, fn p, acc ->
        Map.put(acc, {p.session_id, p.file}, p.position)
      end)

    if more do
      %{s | points: points}
    else
      notify(s, {:resume, points})
      pump(%{s | phase: :live, points: %{}, buffer: Buffer.drop_stored(s.buffer, points)})
    end
  end

  defp hub({:stored, %Proto.Stored{seq: seq}}, s) do
    {before, _} = Buffer.size(s.buffer)
    buffer = Buffer.ack(s.buffer, min(seq, s.sent))
    {left, _} = Buffer.size(buffer)
    notify(s, {:stored, seq})
    pump(%{s | buffer: buffer, in_flight: max(s.in_flight - (before - left), 0)})
  end

  defp hub({:back_soon, _}, s) do
    notify(s, :back_soon)
    %{s | back_soon: true}
  end

  defp hub({:disconnected, _}, s) do
    Logger.warning("Link: the hub removed this machine. It will not connect again.")
    hang_up(s)
    notify(s, :removed)
    %{s | phase: :removed, conn: nil}
  end

  defp hub(_, s), do: s

  # Every hub message with an id is answered, so the hub knows it arrived.
  defp ack(%{conn: %{stream: stream}} = s, id) when id > 0 and stream != nil,
    do: transmit(s, %Proto.FromCollector{body: {:ack, %Proto.Ack{id: id}}})

  defp ack(s, _id), do: s

  # ---------------------------------------------------------------------------
  # Sending

  defp pump(%{phase: :live, pump: nil} = s) do
    room = min(s.pace.per_tick, s.pace.window - s.in_flight)

    {s, sent} =
      s.buffer
      |> Buffer.after_seq(s.sent, max(room, 0))
      |> Enum.reduce_while({s, 0}, fn {seq, payload}, {s, bytes} ->
        cond do
          s.phase != :live ->
            {:halt, {s, bytes}}

          bytes > 0 and bytes + byte_size(payload) > s.pace.bytes_per_tick ->
            {:halt, {s, bytes}}

          true ->
            message = %Proto.FromCollector{seq: seq, body: {:event, Proto.Event.decode(payload)}}
            s = transmit(s, message)

            if s.phase == :live,
              do:
                {:cont,
                 {%{s | sent: seq, in_flight: s.in_flight + 1}, bytes + byte_size(payload)}},
              else: {:halt, {s, bytes}}
        end
      end)

    # More may be waiting than one tick may carry.
    if sent > 0 and s.phase == :live,
      do: %{s | pump: Process.send_after(self(), :pump, s.pace.tick_ms)},
      else: s
  end

  defp pump(s), do: s

  # A send that fails means the stream is gone. Nothing is lost: the event
  # is still in the buffer.
  defp transmit(%{conn: %{stream: stream}} = s, message) when stream != nil do
    GRPC.Stub.send_request(stream, message)
    s
  rescue
    e -> down(s, e)
  catch
    _, reason -> down(s, reason)
  end

  defp transmit(s, _message), do: s

  # ---------------------------------------------------------------------------
  # The stream's own process: it connects, says hello, then passes on what
  # the hub sends until the stream ends.

  defp session(parent, ref, {host, port, tls, hello, connect_ms, name}) do
    with {:ok, ip} <- :inet.getaddr(String.to_charlist(host), :inet),
         {:ok, channel} <-
           GRPC.Stub.connect("ipv4:#{:inet.ntoa(ip)}:#{port}",
             cred: GRPC.Credential.new(ssl: tls),
             adapter: Adapter,
             # Named, so the client can close it even while it is still
             # connecting.
             name: name,
             connect_timeout: connect_ms,
             adapter_opts: [transport_opts: [timeout: connect_ms]]
           ) do
      try do
        stream = Proto.Collector.Stub.stream(channel)
        GRPC.Stub.send_request(stream, %Proto.FromCollector{body: {:hello, hello}})
        send(parent, {:link_up, ref, channel, stream})

        reason =
          case GRPC.Stub.recv(stream) do
            {:ok, replies} ->
              Enum.reduce_while(replies, :closed, fn
                {:ok, message}, acc ->
                  send(parent, {:link_message, ref, message})
                  {:cont, acc}

                {:error, error}, _ ->
                  {:halt, error}

                _, acc ->
                  {:cont, acc}
              end)

            {:error, error} ->
              error
          end

        send(parent, {:link_down, ref, reason})
      after
        disconnect(name)
      end
    else
      {:error, reason} -> send(parent, {:link_down, ref, reason})
    end
  end

  # The gRPC library keeps a process per connection, under this name. Left
  # alone it would keep trying the hub on its own.
  defp disconnect(name) do
    GRPC.Client.Connection.disconnect(name)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Losing the stream

  defp down(%{phase: phase} = s, _reason) when phase in [:waiting, :removed], do: s

  defp down(s, reason) do
    hang_up(s)

    {wait, backoff} =
      if s.back_soon, do: Backoff.back_soon(s.backoff), else: Backoff.next(s.backoff)

    Logger.info("Link: no connection to the hub (#{brief(reason)}). Trying again in #{wait} ms.")
    notify(s, {:down, wait})
    if s.pump, do: Process.cancel_timer(s.pump)
    Process.send_after(self(), :connect, wait)

    %{s | phase: :waiting, conn: nil, backoff: backoff, back_soon: false, pump: nil, in_flight: 0}
  end

  defp hang_up(%{conn: nil}), do: :ok

  defp hang_up(%{conn: conn}) do
    Process.demonitor(conn.mon, [:flush])
    Process.exit(conn.pid, :kill)
    disconnect(conn.ref)
  end

  defp brief(%{message: message}) when is_binary(message), do: message
  defp brief(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp brief(reason), do: reason |> inspect() |> String.slice(0, 200)

  defp notify(%{listener: nil}, _what), do: :ok
  defp notify(%{listener: pid}, what), do: send(pid, {:wallboard_link, what})

  defp now, do: System.monotonic_time(:millisecond)
end
