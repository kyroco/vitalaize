defmodule Wallboard.Link.Buffer do
  @moduledoc """
  The collector's events that the hub has not confirmed yet, kept in one
  file so they outlive a restart of the collector and any time the hub is
  away.

  Each event gets a number, `seq`, that counts up. `ack/2` forgets every
  event up to a number once the hub says it stored them.

  The buffer is bounded. When it passes `max_bytes` it sheds, in this order:
  a status that a later status of the same session replaced, then the oldest
  events that came from a file. A session's latest status and its end are
  never shed. A shed file event is not lost: its line is still in the
  session file, and the hub's `Resume` says where to read on from.
  `take_shed/1` tells the caller it happened.

  The file is a run of records: the event's size, a checksum, its seq and
  the event. A confirmation from the hub adds a short record that says
  "forget everything up to this seq", so a restart does not bring confirmed
  events back. A half-written record at the end, from a crash, is cut off
  when the file is opened. Every event is flushed to the disk before
  `push/2` returns.

  One process owns a buffer; nothing here is safe to share.
  """

  alias Wallboard.Collector.Proto

  defstruct [:path, :io, :max_bytes, :entries, :bytes, :file_bytes, :next_seq, shed: false]

  @header 16
  # In place of a size, this marks a record that forgets events.
  @forget 0xFFFFFFFF
  @default_max 20_000_000
  # Rewriting the file is put off until this much of it is dead weight.
  @slack 1_000_000

  @doc """
  Opens the buffer at `path`, making it when it is not there. Options:
  `max_bytes`, 20 MB unless given.
  """
  def open(path, opts \\ []) do
    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, "")
    # It holds prompts and titles: for the owner only.
    File.chmod!(path, 0o600)

    data = File.read!(path)
    {entries, last, good} = parse(data, :gb_trees.empty(), 0, 0)
    if good < byte_size(data), do: truncate!(path, good)
    bytes = entries |> :gb_trees.values() |> Enum.reduce(0, &(&1.size + &2))

    %__MODULE__{
      path: path,
      io: append!(path),
      max_bytes: opts[:max_bytes] || @default_max,
      entries: entries,
      bytes: bytes,
      file_bytes: good,
      # Past every seq the file has seen, forgotten ones too, so none is
      # ever given out twice.
      next_seq: last + 1
    }
    |> tidy()
  end

  @doc "Closes the file. The buffer cannot be used after."
  def close(%__MODULE__{io: io}), do: :file.close(io)

  @doc """
  Adds events, each with the next seq, and returns the buffer. They are on
  disk when this returns: one write and one flush for the whole list.
  """
  def push(%__MODULE__{} = b, %Proto.Event{} = event), do: push(b, [event])

  def push(%__MODULE__{} = b, events) when is_list(events) do
    {entries, records, b} =
      Enum.reduce(events, {b.entries, [], b}, fn %Proto.Event{} = event, {entries, records, b} ->
        seq = b.next_seq
        payload = Proto.Event.encode(event)
        entry = entry(seq, event, payload)

        b = %{
          b
          | bytes: b.bytes + entry.size,
            file_bytes: b.file_bytes + entry.size,
            next_seq: seq + 1
        }

        {:gb_trees.insert(seq, entry, entries), [record(seq, payload) | records], b}
      end)

    if records != [] do
      :ok = :file.write(b.io, Enum.reverse(records))
      :ok = :file.datasync(b.io)
    end

    b = %{b | entries: entries}
    if b.bytes > b.max_bytes, do: shed(b), else: b
  end

  @doc "Forgets every event with this seq or an earlier one: the hub has them."
  def ack(%__MODULE__{} = b, seq) when is_integer(seq) do
    case drop(b, fn e -> e.seq <= seq end) do
      ^b ->
        b

      dropped ->
        # Not flushed: if a crash loses this note, the events are sent
        # once more, which the hub takes in its stride.
        :ok = :file.write(b.io, <<@forget::32, :erlang.crc32(<<seq::64>>)::32, seq::64>>)
        tidy(%{dropped | file_bytes: dropped.file_bytes + @header})
    end
  end

  @doc """
  Forgets the file events the hub already has. `points` maps
  `{session_id, file}` to the hub's position in that file.
  """
  def drop_stored(%__MODULE__{} = b, points) when is_map(points) do
    case drop(b, fn e ->
           e.kind == :file and e.position <= Map.get(points, {e.session_id, e.file}, -1)
         end) do
      ^b -> b
      dropped -> rewrite(dropped)
    end
  end

  @doc "Up to `limit` events with a seq after `seq`, oldest first, as `{seq, encoded event}`."
  def after_seq(%__MODULE__{entries: entries}, seq, limit) do
    (seq + 1) |> :gb_trees.iterator_from(entries) |> take(limit, [])
  end

  @doc "How many events wait, and their size on disk in bytes."
  def size(%__MODULE__{entries: entries, bytes: bytes}), do: {:gb_trees.size(entries), bytes}

  @doc "`{true, buffer}` once after the buffer shed file events, `{false, buffer}` otherwise."
  def take_shed(%__MODULE__{shed: shed} = b), do: {shed, %{b | shed: false}}

  # ---------------------------------------------------------------------------

  defp take(_iter, 0, acc), do: Enum.reverse(acc)

  defp take(iter, n, acc) do
    case :gb_trees.next(iter) do
      {seq, entry, iter} -> take(iter, n - 1, [{seq, entry.payload} | acc])
      :none -> Enum.reverse(acc)
    end
  end

  defp entry(seq, event, payload) do
    kind =
      cond do
        event.file != "" -> :file
        Enum.any?(event.items, &match?(%Proto.Item{body: {:ended, _}}, &1)) -> :ended
        true -> :status
      end

    %{
      seq: seq,
      kind: kind,
      session_id: event.session_id,
      file: event.file,
      position: event.position,
      payload: payload,
      size: @header + byte_size(payload)
    }
  end

  defp record(seq, payload),
    do: [<<byte_size(payload)::32, :erlang.crc32(payload)::32, seq::64>>, payload]

  # Stops at the first record that is cut short or fails its checksum.
  # Returns the events still wanted, the highest seq seen and how many
  # bytes of the file were good.
  defp parse(<<@forget::32, crc::32, seq::64, rest::binary>>, acc, last, at) do
    if :erlang.crc32(<<seq::64>>) == crc do
      kept = for {s, e} <- :gb_trees.to_list(acc), s > seq, do: {s, e}
      parse(rest, :gb_trees.from_orddict(kept), max(last, seq), at + @header)
    else
      {acc, last, at}
    end
  end

  defp parse(
         <<size::32, crc::32, seq::64, payload::binary-size(size), rest::binary>>,
         acc,
         last,
         at
       ) do
    with true <- :erlang.crc32(payload) == crc,
         %Proto.Event{} = event <- decode(payload) do
      acc = :gb_trees.enter(seq, entry(seq, event, payload), acc)
      parse(rest, acc, max(last, seq), at + @header + size)
    else
      _ -> {acc, last, at}
    end
  end

  defp parse(_rest, acc, last, at), do: {acc, last, at}

  defp decode(payload) do
    Proto.Event.decode(payload)
  rescue
    _ -> nil
  end

  defp shed(b) do
    latest =
      for {_, %{kind: :status} = e} <- :gb_trees.to_list(b.entries), into: %{} do
        {e.session_id, e.seq}
      end

    b = drop(b, fn e -> e.kind == :status and latest[e.session_id] != e.seq end)

    # Down to three quarters, so one more event does not shed again at once.
    target = div(b.max_bytes * 3, 4)

    {_, doomed} =
      b.entries
      |> :gb_trees.to_list()
      |> Enum.reduce_while({b.bytes, []}, fn {seq, e}, {bytes, doomed} ->
        cond do
          bytes <= target -> {:halt, {bytes, doomed}}
          e.kind == :file -> {:cont, {bytes - e.size, [seq | doomed]}}
          true -> {:cont, {bytes, doomed}}
        end
      end)

    doomed = MapSet.new(doomed)
    b = if MapSet.size(doomed) > 0, do: %{b | shed: true}, else: b
    b |> drop(fn e -> MapSet.member?(doomed, e.seq) end) |> rewrite()
  end

  defp drop(b, gone?) do
    {entries, bytes} =
      b.entries
      |> :gb_trees.to_list()
      |> Enum.reduce({b.entries, b.bytes}, fn {seq, e}, {entries, bytes} ->
        if gone?.(e), do: {:gb_trees.delete(seq, entries), bytes - e.size}, else: {entries, bytes}
      end)

    %{b | entries: entries, bytes: bytes}
  end

  # The file is only ever added to, so forgotten events stay in it until it
  # is written again.
  defp tidy(b) do
    dead = b.file_bytes - b.bytes
    if dead > @slack or (b.bytes == 0 and dead > @header), do: rewrite(b), else: b
  end

  # Written beside the file and moved over it, so a crash leaves the old
  # file or the new one, never half of either.
  defp rewrite(b) do
    :ok = :file.close(b.io)
    tmp = b.path <> ".tmp"
    {:ok, io} = :file.open(tmp, [:write, :binary, :raw])
    :ok = :file.change_mode(tmp, 0o600)

    # First a note of the last seq given out, so the count carries on
    # after a restart even when no event is left.
    last = b.next_seq - 1
    :ok = :file.write(io, <<@forget::32, :erlang.crc32(<<last::64>>)::32, last::64>>)

    for {seq, e} <- :gb_trees.to_list(b.entries) do
      :ok = :file.write(io, record(seq, e.payload))
    end

    :ok = :file.datasync(io)
    :ok = :file.close(io)
    File.rename!(tmp, b.path)
    %{b | io: append!(b.path), file_bytes: b.bytes + @header}
  end

  defp truncate!(path, size) do
    {:ok, io} = :file.open(path, [:read, :write, :binary, :raw])
    {:ok, _} = :file.position(io, size)
    :ok = :file.truncate(io)
    :ok = :file.close(io)
  end

  defp append!(path) do
    {:ok, io} = :file.open(path, [:append, :binary, :raw])
    io
  end
end
