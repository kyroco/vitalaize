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

  @doc """
  Returns {:ok, stdout} on exit status 0, or {:error, reason}.

  Options: :env (list of {name, value}), :timeout in milliseconds, and
  :input, one line of text for the program's standard input. Use :input
  for a key or a password: it never goes on a command line. With :input,
  the program's standard error is not read, so a failure says only its
  exit status.
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

    # `sh -c 'exec "$0" "$@" 2>file'` sends stderr to a file while every
    # argument reaches the program untouched, with no shell parsing.
    script = ~s(exec "$0" "$@" 2>"$WALLBOARD_ERR_FILE")

    task =
      Task.async(fn ->
        System.cmd("/bin/sh", ["-c", script, exe | args],
          env: [{"WALLBOARD_ERR_FILE", err_file} | env]
        )
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {out, 0}} ->
          {:ok, out}

        {:ok, {_out, status}} ->
          {:error, "#{program} exited with #{status}: #{first_line(File.read(err_file))}"}

        nil ->
          {:error, "#{program} took longer than #{div(timeout, 1000)}s"}

        {:exit, reason} ->
          {:error, "#{program} failed: #{inspect(reason)}"}
      end

    File.rm(err_file)
    result
  end

  defp run_with_input(program, exe, args, input, timeout, env) do
    if is_binary(input) and not String.contains?(input, ["\n", "\r"]) do
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          :exit_status,
          args: ["-c", @with_input, exe | args],
          env: Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
        ])

      Port.command(port, input <> "\n")
      collect(port, program, [], timeout)
    else
      {:error, "#{program} takes one line of input"}
    end
  end

  defp collect(port, program, out, timeout) do
    receive do
      {^port, {:data, data}} -> collect(port, program, [out | data], timeout)
      {^port, {:exit_status, 0}} -> {:ok, IO.iodata_to_binary(out)}
      {^port, {:exit_status, status}} -> {:error, "#{program} exited with #{status}"}
    after
      timeout ->
        Port.close(port)
        {:error, "#{program} took longer than #{div(timeout, 1000)}s"}
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
