defmodule Wallboard.Archive.UploadGate do
  @moduledoc """
  How much of the hub other machines' uploads may use at once.

  Key ids are not secret (every request carries one), so anyone on the
  network who saw one can start an upload before its signature is checked.
  Such an unchecked upload waits on disk, and the gate caps them: at most
  two per key id (a machine's Claude and Codex may send at the same time),
  and at most 2 GB in all, counted from each upload's declared length. Over
  either, the upload is turned away; a collector sends again on its next
  turn.

  A checked upload is unpacked in memory, up to the unpacking limit, so
  only two unpack at once. The rest wait their turn rather than being
  turned away, since they already came in full.

  Each hold belongs to the process that took it and is let go when that
  process ends, however it ends.
  """

  use GenServer

  @max_unchecked 2_000_000_000
  @per_key 2
  @unpacks 2

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Lets an upload of `bytes`, signed with `key_id`, be read. :ok, or
  {:error, reason} when it would pass a cap.
  """
  def admit(key_id, bytes), do: GenServer.call(__MODULE__, {:admit, key_id, bytes})

  @doc "The caller's upload is checked (or refused): its hold on the caps goes."
  def checked, do: GenServer.call(__MODULE__, :checked)

  @doc "Runs `fun` once fewer than @unpacks uploads are unpacking, waiting if needed."
  def unpack(fun) do
    :ok = GenServer.call(__MODULE__, :unpack, :infinity)

    try do
      fun.()
    after
      GenServer.call(__MODULE__, :unpacked)
    end
  end

  @impl true
  def init(_opts),
    do: {:ok, %{unchecked: %{}, unpacking: %{}, waiting: :queue.new()}}

  @impl true
  def handle_call({:admit, key_id, bytes}, {pid, _}, state) do
    held = Map.values(state.unchecked)
    total = held |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    cond do
      Enum.count(held, &(elem(&1, 1) == key_id)) >= @per_key ->
        {:reply, {:error, "this machine is already sending: this one goes again next time"},
         state}

      total + bytes > @max_unchecked ->
        {:reply, {:error, "the hub is busy with other uploads: this one goes again next time"},
         state}

      true ->
        ref = Process.monitor(pid)
        {:reply, :ok, put_in(state.unchecked[pid], {ref, key_id, bytes})}
    end
  end

  def handle_call(:checked, {pid, _}, state), do: {:reply, :ok, drop_unchecked(state, pid)}

  def handle_call(:unpack, {pid, _} = from, state) do
    if map_size(state.unpacking) < @unpacks,
      do: {:reply, :ok, start_unpack(state, pid)},
      else: {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
  end

  def handle_call(:unpacked, {pid, _}, state), do: {:reply, :ok, drop_unpacking(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    waiting = :queue.filter(fn {p, _} -> p != pid end, state.waiting)
    {:noreply, %{state | waiting: waiting} |> drop_unchecked(pid) |> drop_unpacking(pid)}
  end

  defp start_unpack(state, pid),
    do: put_in(state.unpacking[pid], Process.monitor(pid))

  defp drop_unchecked(state, pid) do
    case Map.pop(state.unchecked, pid) do
      {nil, _} ->
        state

      {{ref, _, _}, rest} ->
        Process.demonitor(ref, [:flush])
        %{state | unchecked: rest}
    end
  end

  # The next one waiting, if any, starts in the freed place.
  defp drop_unpacking(state, pid) do
    case Map.pop(state.unpacking, pid) do
      {nil, _} ->
        state

      {ref, rest} ->
        Process.demonitor(ref, [:flush])

        case :queue.out(state.waiting) do
          {{:value, {next, _} = from}, waiting} ->
            GenServer.reply(from, :ok)
            start_unpack(%{state | unpacking: rest, waiting: waiting}, next)

          {:empty, _} ->
            %{state | unpacking: rest}
        end
    end
  end
end
