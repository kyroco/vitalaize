defmodule Wallboard.Collector.Runners do
  @moduledoc """
  The GitHub Actions runners running on the collector's machine now, read
  from the process list. It only looks: nothing here installs, starts, stops
  or changes a runner.

  GitHub's runner keeps everything in the folder it was set up in. Its
  program `Runner.Listener` (in that folder's `bin`) runs while the runner
  is connected to GitHub and waiting for work, and it starts a
  `Runner.Worker` from the same place for each job it runs. So:

    * a `Runner.Listener` means the runner is online
    * a `Runner.Worker` from the same folder means it is busy

  The runner's name is in the `.runner` file of that folder (its
  `agentName`). A runner is often run as a user of its own, whose folder
  the collector's user may not read. Such a runner has no name here, so it
  is left out, and `read/1` says which folders those are so the caller can
  say so once. The process list names no runner, and the service name a
  runner may be installed under is cut short and numbered when it is long,
  so neither is used as a name.

  What `read/1` returns goes through `Wallboard.Collector.Filter.runners/1`
  before it leaves the machine: only each name and state cross.
  """

  # `ps` is the same on macOS and Linux in this form: every process, every
  # user, the full command line, no header.
  @ps_args ["axww", "-o", "command="]
  @ps_timeout_ms 5_000
  # A `.runner` file is a few hundred bytes.
  @file_max 64_000
  # How long reading one may take.
  @read_timeout_ms 1_000

  @doc """
  The runners running now: `{runners, unnamed}`, where `runners` is
  `[%{name, state}]` sorted by name, with `state` `:online` or `:busy`,
  and `unnamed` is the folders of runners whose name could not be read.

  `processes` gives the process list, one command line each, as
  `{:ok, [line]}` or `:error`; `processes/0` unless given (tests pass
  their own). `read_timeout_ms` is how long reading one `.runner` may take.
  """
  def read(processes \\ &processes/0, read_timeout_ms \\ @read_timeout_ms) do
    case processes.() do
      {:ok, lines} ->
        folders = parse(lines)

        {named, unnamed} =
          Enum.reduce(folders, {%{}, []}, fn {folder, state}, {named, unnamed} ->
            case name(folder, read_timeout_ms) do
              {:ok, name} -> {Map.update(named, name, state, &busiest(&1, state)), unnamed}
              :error -> {named, [folder | unnamed]}
            end
          end)

        runners =
          named
          |> Enum.map(fn {name, state} -> %{name: name, state: state} end)
          |> Enum.sort_by(& &1.name)

        {runners, Enum.sort(unnamed)}

      _ ->
        :error
    end
  end

  @doc """
  The runner folders in a process list, `%{folder => :online | :busy}`.
  A line counts when it starts with the full path of `Runner.Listener` or
  `Runner.Worker` in a folder's `bin` (or `bin.<version>`, where a runner
  that updated itself may run from).
  """
  def parse(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case Regex.run(
             ~r"\A(/.*?)/bin(?:\.[^/\s]+)?/Runner\.(Listener|Worker)(?:\s|\z)",
             String.trim_leading(line),
             capture: :all_but_first
           ) do
        [folder, "Worker"] -> Map.put(acc, folder, :busy)
        [folder, "Listener"] -> Map.update(acc, folder, :online, &busiest(&1, :online))
        _ -> acc
      end
    end)
  end

  defp busiest(:busy, _), do: :busy
  defp busiest(_, state), do: state

  @doc """
  The name GitHub knows the runner set up in `folder` by, from its
  `.runner` file: `{:ok, name}`, or `:error` when the file cannot be read
  or holds no name, or reading it takes longer than `read_timeout_ms`.
  """
  def name(folder, read_timeout_ms \\ @read_timeout_ms) do
    path = Path.join(folder, ".runner")

    # Any program here can start a Runner.Listener from a folder it made, so
    # the file may be anything. Only a plain file is read: a named pipe
    # would hold this process forever, and a link could lead to a device
    # that never ends. `lstat` does not follow a link, and the read stops
    # at the size limit even if the file grew since.
    with {:ok, %{type: :regular, size: size}} when size <= @file_max <- File.lstat(path),
         {:ok, text} <- read_at_most(path, @file_max, read_timeout_ms),
         true <- byte_size(text) <= @file_max,
         # The runner writes the file with a byte order mark first.
         text = String.replace_prefix(text, "﻿", ""),
         {:ok, %{} = settings} <- Jason.decode(text),
         name when is_binary(name) and name != "" <- agent_name(settings) do
      {:ok, name}
    else
      _ -> :error
    end
  end

  # One byte past the limit, so a file over it is seen to be over it.
  #
  # The file can be swapped for a named pipe between the look above and
  # the open, and opening a pipe waits for a writer. An open by this
  # program could neither be timed out nor stopped, so a small `head` does
  # the reading, and is killed if it takes too long (a second, unless told).
  defp read_at_most(path, max, timeout_ms) do
    case System.find_executable("head") do
      nil ->
        :error

      head ->
        port =
          Port.open({:spawn_executable, head}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["-c", Integer.to_string(max + 1), "--", path]
          ])

        deadline = System.monotonic_time(:millisecond) + timeout_ms
        collect(port, [], deadline)
    end
  end

  defp collect(port, acc, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, [acc | data], deadline)
      {^port, {:exit_status, 0}} -> {:ok, IO.iodata_to_binary(acc)}
      {^port, {:exit_status, _}} -> :error
    after
      left ->
        stop(port)
        :error
    end
  end

  defp stop(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid),
         do: System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    receive do
      {^port, _} -> :ok
    after
      0 -> :ok
    end
  end

  # The runner's JSON names its fields in camel case ("agentName"); an
  # older or hand-written file may say "AgentName".
  defp agent_name(settings) do
    Enum.find_value(settings, fn {key, value} ->
      if is_binary(key) and String.downcase(key) == "agentname", do: value
    end)
  end

  @doc """
  This machine's process list, one command line each: `{:ok, lines}`, or
  `:error` when `ps` cannot be run or takes too long.
  """
  def processes do
    task =
      Task.async(fn ->
        try do
          System.cmd("ps", @ps_args, stderr_to_stdout: true)
        rescue
          _ -> :error
        end
      end)

    case Task.yield(task, @ps_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> {:ok, String.split(out, "\n", trim: true)}
      _ -> :error
    end
  end
end
