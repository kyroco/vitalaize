defmodule Wallboard.RunJobs do
  @moduledoc """
  The jobs of finished runs, read from GitHub for the Git tab's run panel,
  once for every screen of this board.

  A run's jobs are read once and kept. A screen that asks while a read is
  going waits for that same read. A read that failed is not tried again
  for a minute. At most four reads go at a time, the rest wait their turn.
  So however often, and from however many screens, people tap, GitHub sees
  at most one call for each finished run the board lists, and one a minute
  for a run whose read keeps failing.

  When the archive is on, the jobs read are saved there too, so the
  archive does not read them again and a restarted board finds them.
  """

  use GenServer

  alias Wallboard.Sources.GitHub
  alias Wallboard.Store

  # How many runs' jobs are kept, and how many reads may go at once.
  @keep 1_000
  @at_once 4

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  A finished run's jobs, {:ok, rows} or {:error, why}, read from GitHub
  only when they are not known yet. Waits for that read.
  """
  def get(repo, run_id, attempt),
    do: GenServer.call(__MODULE__, {:get, {repo, run_id, attempt}}, 120_000)

  @impl true
  def init(opts) do
    {:ok,
     %{
       retry_ms: Keyword.get(opts, :retry_ms, 60_000),
       kept: %{},
       kept_order: :queue.new(),
       failed: %{},
       waiting: %{},
       queue: :queue.new(),
       running: %{}
     }}
  end

  @impl true
  def handle_call({:get, key}, from, s) do
    cond do
      Map.has_key?(s.kept, key) ->
        {:reply, {:ok, s.kept[key]}, s}

      recent_failure(s, key) ->
        {:reply, {:error, recent_failure(s, key)}, s}

      Map.has_key?(s.waiting, key) ->
        {:noreply, update_in(s.waiting[key], &[from | &1])}

      true ->
        s = %{s | waiting: Map.put(s.waiting, key, [from]), queue: :queue.in(key, s.queue)}
        {:noreply, start_reads(s)}
    end
  end

  # Why the last read of `key` failed, while it is too soon to try again.
  defp recent_failure(s, key) do
    case s.failed[key] do
      {why, at} -> if System.monotonic_time(:millisecond) - at < s.retry_ms, do: why
      nil -> nil
    end
  end

  @impl true
  def handle_info({ref, result}, %{running: running} = s) when is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, s |> done(ref, result) |> start_reads()}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{running: running} = s)
      when is_map_key(running, ref),
      do: {:noreply, s |> done(ref, {:error, "the read stopped"}) |> start_reads()}

  def handle_info(_, s), do: {:noreply, s}

  defp start_reads(s) do
    with true <- map_size(s.running) < @at_once,
         {{:value, key}, queue} <- :queue.out(s.queue) do
      task = Task.Supervisor.async_nolink(Wallboard.TaskSupervisor, fn -> read(key) end)
      start_reads(%{s | queue: queue, running: Map.put(s.running, task.ref, key)})
    else
      _ -> s
    end
  end

  defp read({repo, run_id, _attempt}) do
    with {:ok, rows} <- GitHub.fetch_run_jobs(repo, run_id) do
      if archive?(), do: Store.put_jobs(repo, run_id, rows)
      {:ok, rows}
    end
  end

  defp archive? do
    Wallboard.Settings.get().archive.enabled and is_pid(Process.whereis(Store))
  end

  defp done(s, ref, result) do
    {key, running} = Map.pop(s.running, ref)
    {froms, waiting} = Map.pop(s.waiting, key, [])
    Enum.each(froms, &GenServer.reply(&1, result))
    s = %{s | running: running, waiting: waiting}

    case result do
      {:ok, rows} -> keep(s, key, rows)
      {:error, why} -> failed(s, key, why)
    end
  end

  defp keep(s, key, rows) do
    s = %{s | kept: Map.put(s.kept, key, rows), kept_order: :queue.in(key, s.kept_order)}

    if map_size(s.kept) > @keep do
      {{:value, old}, order} = :queue.out(s.kept_order)
      %{s | kept: Map.delete(s.kept, old), kept_order: order}
    else
      s
    end
  end

  # Failures older than the wait are dropped as new ones come, so the list
  # stays as long as the runs failing right now.
  defp failed(s, key, why) do
    now = System.monotonic_time(:millisecond)

    failed =
      s.failed
      |> Map.reject(fn {_, {_, at}} -> now - at >= s.retry_ms end)
      |> Map.put(key, {why, now})

    %{s | failed: failed}
  end
end
