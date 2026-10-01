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
  The watcher adds a couple of hundred events at a time and asks again
  after each, so the outbox goes over the limit by one such batch at most
  (a few megabytes when every event is as large as an event can be).

  An append the disk refuses (full, or not writable) answers
  `{:error, reason}` and leaves nothing behind. The watcher then waits and
  tries again. A saved point that cannot be read is rebuilt from the event
  files, which are kept.

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
  outbox, or `{:error, reason}` when the disk would not take them, in which
  case nothing of the append is kept.
  """
  def append(server \\ __MODULE__, events, checkpoint) when is_binary(checkpoint),
    do: GenServer.call(server, {:append, events, checkpoint}, :infinity)

  @doc """
  The checkpoint given to the last `append/3`, nil when there is none, or
  `{:error, :outbox_unreadable}` while the outbox cannot read its files.
  """
  def checkpoint(server \\ __MODULE__), do: GenServer.call(server, :checkpoint, 60_000)

  @doc "False when the outbox is full, or cannot be read, and the watcher should wait."
  def room?(server \\ __MODULE__), do: GenServer.call(server, :room?, 60_000)

  @doc "Up to `limit` events numbered after `seq`, oldest first, as {number, event}."
  def read(server \\ __MODULE__, seq, limit \\ 500),
    do: GenServer.call(server, {:read, seq, limit}, 60_000)

  @doc "Every event up to and including `seq` has reached the hub; they can go."
  def ack(server \\ __MODULE__, seq), do: GenServer.call(server, {:ack, seq}, 60_000)

  @doc """
  %{seq: last event's number, acked: last one sent, bytes: size on disk,
  max_bytes: limit, broken?: false}, or only %{broken?: true} while the
  outbox cannot read its files.
  """
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats, 60_000)

  # ---------------------------------------------------------------------------
  # Server

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    state = %{
      dir: dir,
      max_bytes: Keyword.get(opts, :max_bytes, 64_000_000),
      seq: 0,
      acked: 0,
      checkpoint: nil,
      # {number of the first event, how many events, bytes}, oldest first.
      segments: [],
      # Whether the saved point has been read from disk yet, and whether
      # the event files could not be read or put right the last time.
      loaded?: false,
      broken?: false
    }

    {:ok, mend(state)}
  end

  # A file that cannot be read or changed leaves the outbox marked broken
  # rather than stopping it: a stop would print the append in hand, events
  # and all, in the crash report of whoever was waiting for it. While it is
  # broken it gives nothing out and takes nothing in, and every call tries
  # to put it right first.
  defp mend(%{broken?: false, loaded?: true} = state), do: state

  # Not read from disk yet: the saved point, then the files lined up to it.
  defp mend(%{loaded?: false} = state) do
    opened =
      case load(state.dir) do
        :damaged -> rebuild(state)
        saved -> %{state | segments: []} |> Map.merge(saved) |> recover() |> drop_sent()
      end

    %{opened | loaded?: true, broken?: false}
  rescue
    _ -> broken(state)
  end

  # Read before: the numbers in memory are the saved ones, so the files are
  # lined up to those. The saved point is not read again, since an append
  # that failed must not be taken for saved.
  defp mend(state) do
    %{recover(%{state | segments: []}) | broken?: false} |> drop_sent()
  rescue
    _ -> broken(state)
  end

  defp broken(state) do
    if not state.broken?,
      do: Logger.warning("Collector: the outbox's files cannot be read. It will try again.")

    %{state | broken?: true}
  end

  @impl true
  def handle_call(call, _from, state) do
    case mend(state) do
      %{broken?: true} = state -> {:reply, unreadable(call), state}
      state -> answer(call, state)
    end
  end

  # What each call gets while the outbox cannot be read: no events, no
  # room, and no saved point (which is not the same as an empty one).
  defp unreadable({:append, _, _}), do: {:error, :outbox_unreadable}
  defp unreadable(:checkpoint), do: {:error, :outbox_unreadable}
  defp unreadable(:room?), do: false
  defp unreadable({:read, _, _}), do: []
  defp unreadable({:ack, _}), do: :ok
  defp unreadable(:stats), do: %{broken?: true}

  defp answer({:append, [], checkpoint}, %{checkpoint: checkpoint} = state),
    do: {:reply, state.seq, state}

  defp answer({:append, events, checkpoint}, state) do
    with {:ok, written} <- events |> Enum.map(&record/1) |> write(state),
         written = %{written | checkpoint: checkpoint},
         :ok <- save(written) do
      {:reply, written.seq, written}
    else
      # Nothing of a failed append stays: the files go back to the last
      # saved point, and the caller tries again later.
      {:error, reason} -> {:reply, {:error, reason}, mend(%{state | broken?: true})}
    end
  end

  defp answer(:checkpoint, state), do: {:reply, state.checkpoint, state}
  defp answer(:room?, state), do: {:reply, bytes(state) < state.max_bytes, state}

  # A file that cannot be read is never stepped over: its events would be
  # missed, and an ack of the later ones would then remove them unsent.
  defp answer({:read, seq, limit}, state) do
    wanted = Enum.filter(state.segments, fn {first, count, _} -> first + count - 1 > seq end)

    read =
      Enum.reduce_while(wanted, [], fn {first, _, _}, acc ->
        with true <- length(acc) < limit,
             {:ok, bin} <- File.read(path(state.dir, first)) do
          {records, _} = records(bin)

          found =
            for {body, n} <- Enum.with_index(records, first),
                # Never past the saved point, whatever a file holds.
                n > seq and n <= state.seq,
                do: {n, body}

          {:cont, acc ++ found}
        else
          false -> {:halt, acc}
          {:error, _} -> {:halt, :unreadable}
        end
      end)

    case read do
      :unreadable ->
        {:reply, [], broken(state)}

      events ->
        events =
          events |> Enum.take(limit) |> Enum.map(fn {n, b} -> {n, Proto.Event.decode(b)} end)

        {:reply, events, state}
    end
  end

  defp answer({:ack, seq}, state) when is_integer(seq) do
    state = drop_sent(%{state | acked: seq |> max(state.acked) |> min(state.seq)})
    # Unsaved, a restart only offers the hub some events again.
    save(state)
    {:reply, :ok, state}
  end

  defp answer(:stats, state) do
    stats = Map.take(state, [:seq, :acked, :max_bytes, :broken?])
    {:reply, Map.put(stats, :bytes, bytes(state)), state}
  end

  # Never print events or the checkpoint in a crash report.
  @impl true
  def format_status(status),
    do:
      status
      |> Map.update(:state, nil, &Map.take(&1, [:dir, :seq, :acked]))
      |> Map.replace(:message, :not_shown)
      |> Map.replace(:log, [])

  # ---------------------------------------------------------------------------
  # Files

  defp path(dir, first),
    do: Path.join(dir, "events-" <> String.pad_leading("#{first}", 20, "0") <> ".log")

  defp record(%Proto.Event{} = event) do
    body = Proto.Event.encode(event)
    <<byte_size(body)::32, body::binary>>
  end

  # Adds to the newest file until it is full, then starts another.
  defp write([], state), do: {:ok, state}

  defp write(records, state) do
    {{first, count, size}, kept} =
      case List.last(state.segments) do
        {_, _, size} = last when size < @segment_bytes -> {last, Enum.drop(state.segments, -1)}
        _ -> {{state.seq + 1, 0, 0}, state.segments}
      end

    file = path(state.dir, first)
    new? = count == 0

    with {:ok, io} <- :file.open(file, [:append, :binary, :raw]),
         result = write_synced(io, file, new?, records),
         :ok <- :file.close(io),
         :ok <- result do
      segment = {first, count + length(records), size + IO.iodata_length(records)}
      {:ok, %{state | segments: kept ++ [segment], seq: state.seq + length(records)}}
    end
  end

  defp write_synced(io, file, new?, records) do
    with :ok <- if(new?, do: File.chmod(file, 0o600), else: :ok),
         :ok <- :file.write(io, records) do
      :file.datasync(io)
    end
  end

  # Written beside itself and moved into place, so a stop halfway leaves
  # the old one whole.
  defp save(state) do
    file = Path.join(state.dir, "state")
    tmp = file <> ".tmp"
    saved = %{"seq" => state.seq, "acked" => state.acked, "checkpoint" => state.checkpoint}

    with :ok <- File.write(tmp, ""),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, Jason.encode!(saved), [:sync]) do
      File.rename(tmp, file)
    end
  end

  defp load(dir) do
    case File.read(Path.join(dir, "state")) do
      {:ok, text} ->
        with {:ok, %{"seq" => seq, "acked" => acked, "checkpoint" => checkpoint}} <-
               Jason.decode(text),
             true <- is_integer(seq) and is_integer(acked) and acked >= 0 and acked <= seq,
             true <- is_nil(checkpoint) or is_binary(checkpoint) do
          %{seq: seq, acked: acked, checkpoint: checkpoint}
        else
          _ -> :damaged
        end

      # No saved point. Beside no event file, or only the very first one,
      # nothing was ever saved: the collector stopped during its first
      # append, and those events are made again. Beside any other event
      # file the saved point was lost, and the numbers must carry on.
      {:error, :enoent} ->
        names = Enum.filter(File.ls!(dir), &(&1 =~ ~r/\Aevents-\d{20}\.log\z/))

        if names -- [Path.basename(path(dir, 1))] == [],
          do: %{seq: 0, acked: 0, checkpoint: nil},
          else: :damaged

      # There, but it cannot be read. It may be whole, so it is left alone
      # and the outbox stays broken until it can be read.
      {:error, reason} ->
        raise File.Error, reason: reason, action: "read file", path: Path.join(dir, "state")
    end
  end

  # With no saved point to go by, the event files say what there is: every
  # whole event in them is kept and the numbers carry on from the last. The
  # caller's place is gone, so it starts over and some events come twice,
  # which the hub takes in its stride.
  defp rebuild(state) do
    state = recover(%{state | seq: :all})
    Logger.warning("Collector: the outbox's saved point was damaged. It was rebuilt.")

    {seq, acked} =
      case {List.first(state.segments), List.last(state.segments)} do
        {{first, _, _}, {last, count, _}} -> {last + count - 1, first - 1}
        _ -> {0, 0}
      end

    state = %{state | seq: seq, acked: acked, checkpoint: nil}
    save(state)
    state
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
    kept = if seq == :all, do: all, else: Enum.take(all, max(seq - first + 1, 0))
    size = kept |> Enum.map(&(byte_size(&1) + 4)) |> Enum.sum()

    cond do
      # An empty file named for the next number stays: see `drop_sent/1`.
      kept == [] and seq != :all and first != seq + 1 ->
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

  # When every event has been sent, an empty file named for the next number
  # is left, so the numbers can carry on even if the saved point is lost.
  defp drop_sent(state) do
    {sent, kept} =
      Enum.split_with(state.segments, fn {first, count, _} ->
        count > 0 and first + count - 1 <= state.acked
      end)

    for {first, _, _} <- sent, do: File.rm(path(state.dir, first))

    kept =
      if kept == [] and state.seq > 0 do
        file = path(state.dir, state.seq + 1)
        File.write(file, "")
        File.chmod(file, 0o600)
        [{state.seq + 1, 0, 0}]
      else
        kept
      end

    %{state | segments: kept}
  end

  defp bytes(state), do: state.segments |> Enum.map(&elem(&1, 2)) |> Enum.sum()
end
