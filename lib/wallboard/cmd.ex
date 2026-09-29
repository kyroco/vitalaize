defmodule Wallboard.Cmd do
  @moduledoc """
  Runs a local command (claude, gh, osascript) with a time limit.

  Arguments are passed as a list, never pasted into a shell string, so a
  message or a session name can never be run as a command. Standard error is
  kept apart from the output, so a warning printed by a tool does not break
  the JSON it prints.
  """

  @doc """
  Returns {:ok, stdout} on exit status 0, or {:error, reason}.

  Options: :env (list of {name, value}), :timeout in milliseconds.
  """
  def run(program, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 20_000)
    env = Keyword.get(opts, :env, [])

    case System.find_executable(program) || find_in_common_paths(program) do
      nil ->
        {:error, "#{program} is not installed or not on the PATH"}

      exe ->
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
