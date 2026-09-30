defmodule Wallboard.Archive.UploadGate do
  @moduledoc """
  How many signed uploads the hub takes in at once. An upload's signature
  is checked before its body is read (see MachineKeys.authenticate/1), so
  only a connected machine ever gets here. Each one is read and unpacked
  in memory, up to the unpacking limit, so only two run at once; the rest
  wait their turn rather than being turned away. One that waits too long
  (longer than a collector waits for an answer) is told to come again.

  A place belongs to the process that took it and is let go when that
  process ends, however it ends.
  """

  use GenServer

  @places 2

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs `fun` once one of the places is free, waiting up to `wait` ms for
  it. {:ok, result}, or {:error, :busy} when no place came free in time.
  """
  def run(fun, wait \\ 100_000) do
    case enter(wait) do
      :ok ->
        try do
          {:ok, fun.()}
        after
          GenServer.call(__MODULE__, :leave)
        end

      :busy ->
        {:error, :busy}
    end
  end

  # Waits for a place. On giving up, the wait is withdrawn, and a place
  # given in the meantime is handed back.
  defp enter(wait) do
    GenServer.call(__MODULE__, :enter, wait)
  catch
    :exit, {:timeout, _} ->
      GenServer.call(__MODULE__, :leave)
      :busy
  end

  @impl true
  def init(_opts), do: {:ok, %{inside: %{}, waiting: :queue.new()}}

  @impl true
  def handle_call(:enter, {pid, _} = from, state) do
    if map_size(state.inside) < @places,
      do: {:reply, :ok, let_in(state, pid)},
      else: {:noreply, %{state | waiting: :queue.in({from, Process.monitor(pid)}, state.waiting)}}
  end

  def handle_call(:leave, {pid, _}, state), do: {:reply, :ok, leave(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state), do: {:noreply, leave(state, pid)}

  defp let_in(state, pid), do: put_in(state.inside[pid], Process.monitor(pid))

  # Takes `pid` out, inside or waiting, and lets the next one waiting in.
  defp leave(state, pid) do
    {gone, waiting} = split_waiting(state.waiting, pid)
    Enum.each(gone, fn {_, ref} -> Process.demonitor(ref, [:flush]) end)

    case Map.pop(state.inside, pid) do
      {nil, _} ->
        %{state | waiting: waiting}

      {ref, inside} ->
        Process.demonitor(ref, [:flush])
        next(%{state | inside: inside, waiting: waiting})
    end
  end

  defp split_waiting(queue, pid) do
    {gone, kept} = queue |> :queue.to_list() |> Enum.split_with(fn {{p, _}, _} -> p == pid end)
    {gone, :queue.from_list(kept)}
  end

  defp next(state) do
    case :queue.out(state.waiting) do
      {{:value, {{pid, _} = from, ref}}, waiting} when map_size(state.inside) < @places ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, :ok)
        let_in(%{state | waiting: waiting}, pid)

      _ ->
        state
    end
  end
end
