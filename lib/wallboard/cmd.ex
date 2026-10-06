defmodule Wallboard.Cmd do
  @moduledoc """
  Runs a local command (claude, gh, osascript) with a time limit.

  Arguments are passed as a list, never pasted into a shell string, so a
  message or a session name can never be run as a command. Standard error is
  kept apart from the output, so a warning printed by a tool does not break
  the JSON it prints.
  """

  # The shell reads one line from us and hands it to the program through a
  # pipe that ends after that line, so the program sees the end of its
  # input and stops. printf is built into the shell, so the line is never
  # an argument of any program, where anyone on this machine could see it
  # with ps. Standard error goes nowhere: a program may repeat its input
  # there.
  @with_input ~s(IFS= read -r line; printf '%s\\n' "$line" | "$0" "$@" 2>/dev/null)

  # `sh -c 'exec "$0" "$@" 2>file'` sends stderr to a file while every
  # argument reaches the program untouched, with no shell parsing.
  @plain ~s(exec "$0" "$@" 2>"$WALLBOARD_ERR_FILE")

  # The message that says the time limit has passed. Sent once by a timer
  # when the program starts, so output never moves the limit.
  @time_up {__MODULE__, :time_up}

  @doc """
  Returns {:ok, stdout} on exit status 0, or {:error, reason}.

  Options: :env (list of {name, value}), :timeout in milliseconds, and
  :input, one line of text for the program's standard input. Use :input
  for a key or a password: it never goes on a command line. With :input,
  the program's standard error is not read, so a failure says only its
  exit status.

  When the time limit passes, the program is killed, with everything it
  started, so a stuck program is never left running.
  """
  def run(program, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 20_000)
    env = Keyword.get(opts, :env, [])

    case System.find_executable(program) || find_in_common_paths(program) do
      nil ->
        {:error, "#{program} is not installed or not on the PATH"}

      exe ->
        if Keyword.has_key?(opts, :input),
          do: run_with_input(program, exe, args, opts[:input], timeout, env),
          else: run_plain(program, exe, args, timeout, env)
    end
  end

  defp run_plain(program, exe, args, timeout, env) do
    err_file =
      Path.join(System.tmp_dir!(), "wallboard-#{System.unique_integer([:positive])}.err")

    ended =
      run_port(["-c", @plain, exe | args], [{"WALLBOARD_ERR_FILE", err_file} | env], nil, timeout)

    result =
      case ended do
        {:exit, status} ->
          {:error, "#{program} exited with #{status}: #{first_line(File.read(err_file))}"}

        other ->
          message(other, program, timeout)
      end

    File.rm(err_file)
    result
  end

  defp run_with_input(program, exe, args, input, timeout, env) do
    if is_binary(input) and not String.contains?(input, ["\n", "\r"]) do
      ["-c", @with_input, exe | args]
      |> run_port(env, input <> "\n", timeout)
      |> message(program, timeout)
    else
      {:error, "#{program} takes one line of input"}
    end
  end

  defp message({:ok, out}, _program, _timeout), do: {:ok, out}

  defp message({:exit, status}, program, _timeout),
    do: {:error, "#{program} exited with #{status}"}

  defp message(:time_up, program, timeout),
    do: {:error, "#{program} took longer than #{div(timeout, 1000)}s"}

  # Runs /bin/sh with `args` and waits for it to end or for the limit.
  defp run_port(args, env, input, timeout) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :hide,
        args: args,
        env: Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
      ])

    timer = Process.send_after(self(), @time_up, timeout)
    if input, do: Port.command(port, input)
    result = collect(port, [])

    # A limit that passed as the program ended must not reach the next run.
    Process.cancel_timer(timer)

    receive do
      @time_up -> :ok
    after
      0 -> :ok
    end

    result
  end

  defp collect(port, out) do
    receive do
      {^port, {:data, data}} ->
        collect(port, [out | data])

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(out)}

      {^port, {:exit_status, status}} ->
        {:exit, status}

      @time_up ->
        kill(port)
        :time_up
    end
  end

  # Each program the BEAM starts leads its own process group, so killing the
  # group takes the shell and every program it started. Then wait for the
  # shell's end, so the program is gone, not only told to go.
  defp kill(port) do
    with {:os_pid, pid} when is_integer(pid) <- Port.info(port, :os_pid) do
      System.cmd("/bin/sh", ["-c", kill_group(), Integer.to_string(pid)], stderr_to_stdout: true)
    end

    wait_for_end(port)
  end

  # The shell line that kills the process group led by the process id in $0.
  # /bin/sh is dash on Ubuntu and Debian and bash on a Mac, so it must read
  # the same in both: dash takes no `--`, and bash reads `-s KILL -<id>` as
  # a signal. Public only so a test can run it in each shell.
  @doc false
  def kill_group, do: ~s(kill -KILL "-$0")

  defp wait_for_end(port) do
    receive do
      {^port, {:data, _}} -> wait_for_end(port)
      {^port, {:exit_status, _}} -> :ok
    after
      5_000 -> if Port.info(port), do: Port.close(port)
    end
  end

  defp first_line({:ok, text}) do
    text |> String.split("\n", trim: true) |> List.first("no message") |> String.slice(0, 200)
  end

  defp first_line(_), do: "no message"

  # A release started from Finder or launchd may have a short PATH, so look
  # in the usual install places too.
  defp find_in_common_paths(program) do
    home = System.user_home() || "~"

    [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      Path.join(home, ".local/bin"),
      Path.join(home, ".claude/local"),
      "/usr/bin"
    ]
    |> Enum.map(&Path.join(&1, program))
    |> Enum.find(&File.exists?/1)
  end
end
