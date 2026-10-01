defmodule Wallboard.Collector.Outbox do
  @moduledoc """
  The collector's events that have not reached the hub yet, kept on disk so
  a restart or a hub that is away loses none of them.

  Only what `Wallboard.Collector.Filter` built goes in: each record is one
  encoded `Wallboard.Collector.Proto.Event`. Events are numbered from 1 in
  the order they were added, and that number never starts over.

  ## One saved point for the events and the watcher's place

  `append/3` takes the watcher's own note of where it is (its place in each
  session file and the last status it sent) and saves it with the events,
  events first. When the collector stops between the two, the events past
  the last saved note are dropped on the next start, and the watcher makes
  them again from that note. So an event is in the outbox once, never twice
  and never missing.

  ## Size

  The outbox holds about `max_bytes`. Past that, `room?/1` says no and the
  watcher stops reading until the link has sent some and called `ack/2`.
  Nothing is lost by waiting: the session files are still there to read.
  One append can go over the limit by what one read of a session file
  gives, so the limit is close, not exact.

  ## On disk

  `<dir>/events-<number of its first event>.log` files of about a megabyte,
  each a run of records (a 4-byte length, then the event), and
  `<dir>/state`, the saved point. `ack/2` removes the files whose events
  have all been sent. The folder and its files are readable only by the
  person the collector runs as.
  """

  use GenServer
  require Logger

  alias Wallboard.Collector.Proto

  @segment_bytes 1_000_000
  # Longer than any event the filter builds; a longer length means the file
  # is damaged from there on.
  @record_max 1_000_000

  def start_link(opts) do
    # `name: nil` starts one without a name, for tests.
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Adds events, then saves `checkpoint` (a text of the caller's own making)
  as the point they belong to. Returns the number of the last event in the
  outbox.
  """
  def append(server \\ __MODULE__, events, checkpoint) when is_binary(checkpoint),
    do: GenServer.call(server, {:append, events, checkpoint}, 60_000)

  @doc "The checkpoint given to the last `append/3`, or nil when there is none."
  def checkpoint(server \\ __MODULE__), do: GenServer.call(server, :checkpoint, 60_000)

  @doc "False when the outbox is full and the watcher should wait."
  def room?(server \\ __MODULE__), do: GenServer.call(server, :room?, 60_000)

  @doc "Up to `limit` events numbered after `seq`, oldest first, as {number, event}."
  def read(server \\ __MODULE__, seq, limit \\ 500),
    do: GenServer.call(server, {:read, seq, limit}, 60_000)

  @doc "Every event up to and including `seq` has reached the hub; they can go."
  def ack(server \\ __MODULE__, seq), do: GenServer.call(server, {:ack, seq}, 60_000)

  @doc "%{seq: last event's number, acked: last one sent, bytes: size on disk, max_bytes: limit}."
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats, 60_000)

  # ---------------------------------------------------------------------------
  # Server

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    saved = load(dir)

    state = %{
      dir: dir,
      max_bytes: Keyword.get(opts, :max_bytes, 64_000_000),
      seq: saved.seq,
      acked: saved.acked,
      checkpoint: saved.checkpoint,
      # {number of the first event, how many events, bytes}, oldest first.
      segments: []
    }

    {:ok, state |> recover() |> drop_sent()}
  end

  @impl true
  def handle_call({:append, [], checkpoint}, _from, %{checkpoint: checkpoint} = state),
    do: {:reply, state.seq, state}

  def handle_call({:append, events, checkpoint}, _from, state) do
    state = events |> Enum.map(&record/1) |> write(state)
    state = %{state | checkpoint: checkpoint}
    save(state)
    {:reply, state.seq, state}
  end

  def handle_call(:checkpoint, _from, state), do: {:reply, state.checkpoint, state}
  def handle_call(:room?, _from, state), do: {:reply, bytes(state) < state.max_bytes, state}

  def handle_call({:read, seq, limit}, _from, state) do
    events =
      state.segments
      |> Enum.filter(fn {first, count, _} -> first + count - 1 > seq end)
      |> Stream.flat_map(fn {first, _, _} ->
        {records, _} = records(File.read!(path(state.dir, first)))
        records |> Enum.with_index(first) |> Enum.map(fn {body, n} -> {n, body} end)
      end)
      |> Stream.filter(fn {n, _} -> n > seq end)
      |> Enum.take(limit)
      |> Enum.map(fn {n, body} -> {n, Proto.Event.decode(body)} end)

    {:reply, events, state}
  end

  def handle_call({:ack, seq}, _from, state) when is_integer(seq) do
    state = drop_sent(%{state | acked: seq |> max(state.acked) |> min(state.seq)})
    save(state)
    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:seq, :acked, :max_bytes]) |> Map.put(:bytes, bytes(state)), state}
  end

  # Never print events or the checkpoint in a crash report.
  @impl true
  def format_status(status),
    do: Map.update(status, :state, nil, &Map.take(&1, [:dir, :seq, :acked]))

  # ---------------------------------------------------------------------------
  # Files

  defp path(dir, first),
    do: Path.join(dir, "events-" <> String.pad_leading("#{first}", 20, "0") <> ".log")

  defp record(%Proto.Event{} = event) do
    body = Proto.Event.encode(event)
    <<byte_size(body)::32, body::binary>>
  end

  # Adds to the newest file until it is full, then starts another.
  defp write([], state), do: state

  defp write(records, state) do
    {first, count, size} =
      case List.last(state.segments) do
        {_, _, size} = last when size < @segment_bytes -> last
        _ -> {state.seq + 1, 0, 0}
      end

    file = path(state.dir, first)
    new? = count == 0
    {:ok, io} = :file.open(file, [:append, :binary, :raw])

    try do
      if new?, do: File.chmod!(file, 0o600)
      :ok = :file.write(io, records)
      :ok = :file.datasync(io)
    after
      :file.close(io)
    end

    segment = {first, count + length(records), size + IO.iodata_length(records)}
    kept = if new?, do: state.segments, else: Enum.drop(state.segments, -1)
    %{state | segments: kept ++ [segment], seq: state.seq + length(records)}
  end

  # Written beside itself and moved into place, so a stop halfway leaves
  # the old one whole.
  defp save(state) do
    file = Path.join(state.dir, "state")
    tmp = file <> ".tmp"
    saved = %{"seq" => state.seq, "acked" => state.acked, "checkpoint" => state.checkpoint}
    File.write!(tmp, "")
    File.chmod!(tmp, 0o600)
    File.write!(tmp, Jason.encode!(saved), [:sync])
    File.rename!(tmp, file)
  end

  defp load(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "state")),
         {:ok, %{"seq" => seq, "acked" => acked, "checkpoint" => checkpoint}} <-
           Jason.decode(text),
         true <- is_integer(seq) and is_integer(acked) and acked >= 0 and acked <= seq,
         true <- is_nil(checkpoint) or is_binary(checkpoint) do
      %{seq: seq, acked: acked, checkpoint: checkpoint}
    else
      {:error, :enoent} ->
        %{seq: 0, acked: 0, checkpoint: nil}

      _ ->
        Logger.warning("Collector: the outbox's saved point could not be read. Starting over.")
        %{seq: 0, acked: 0, checkpoint: nil}
    end
  end

  # Lines the files up with the saved point: whatever was written after it
  # goes, a half-written record with it.
  defp recover(state) do
    segments =
      for name <- state.dir |> File.ls!() |> Enum.sort(),
          [_, digits] <- [Regex.run(~r/\Aevents-(\d{20})\.log\z/, name)],
          first = String.to_integer(digits),
          file = Path.join(state.dir, name),
          segment <- keep(file, first, state.seq) do
        segment
      end

    %{state | segments: segments}
  end

  defp keep(file, first, seq) do
    {all, _} = records(File.read!(file))
    kept = Enum.take(all, max(seq - first + 1, 0))
    size = kept |> Enum.map(&(byte_size(&1) + 4)) |> Enum.sum()

    cond do
      kept == [] ->
        File.rm!(file)
        []

      size == File.stat!(file).size ->
        [{first, length(kept), size}]

      true ->
        {:ok, io} = :file.open(file, [:read, :write, :binary, :raw])

        try do
          {:ok, _} = :file.position(io, size)
          :ok = :file.truncate(io)
        after
          :file.close(io)
        end

        [{first, length(kept), size}]
    end
  end

  # The whole records at the start of a file's bytes, and what is left over.
  defp records(bin, acc \\ [])

  defp records(<<n::32, body::binary-size(n), rest::binary>>, acc) when n <= @record_max,
    do: records(rest, [body | acc])

  defp records(rest, acc), do: {Enum.reverse(acc), rest}

  defp drop_sent(state) do
    {sent, kept} =
      Enum.split_with(state.segments, fn {first, count, _} -> first + count - 1 <= state.acked end)

    for {first, _, _} <- sent, do: File.rm(path(state.dir, first))
    %{state | segments: kept}
  end

  defp bytes(state), do: state.segments |> Enum.map(&elem(&1, 2)) |> Enum.sum()
end
