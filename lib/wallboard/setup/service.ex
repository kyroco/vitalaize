defmodule Wallboard.Setup.Service do
  @moduledoc """
  The service that keeps VitalAIze running on this machine: a login item
  on a Mac (launchd), a user service on Linux (systemd). One machine runs
  one: the board, or the collector, whichever its role says.

  `Wallboard.Setup` asks this whether it runs and, when a saved setting
  needs it, to restart it. A restart is a plain stop request (SIGTERM),
  never a kill, so a hub gets to tell its collectors it will be back soon
  (see `Wallboard.Application.prep_stop/1`) before it goes.

  Only a service that runs from the settings being changed counts. A
  service on this machine that names another settings file (a second
  board someone runs for a test, say) is not this one's to restart, and
  is treated as no service at all.

  Options, for tests: `run`, a function `(program, args) -> {output,
  status}` in place of running the program, and `os`, in place of
  `:os.type/0`.
  """

  # The label the VitalAIze app gives its login item, and the one
  # scripts/login-item.sh gives a board built from source.
  @labels ["ai.kyroco.wallboard", "local.wallboard"]
  @unit "vitalaize.service"

  @doc "`:launchd`, `:systemd`, or `:none` when this machine has neither."
  def kind(opts \\ []) do
    case Keyword.get(opts, :os) || :os.type() do
      {:unix, :darwin} -> :launchd
      {:unix, _} -> if tool?("systemctl", opts), do: :systemd, else: :none
      _ -> :none
    end
  end

  @doc """
  `:running`, `:stopped` (set up as a service, not running now) or `:none`
  (not set up as a service here).
  """
  def state(opts \\ []) do
    case kind(opts) do
      :launchd ->
        case loaded(opts) do
          nil -> :none
          {_target, out} -> if out =~ ~r/state = running/, do: :running, else: :stopped
        end

      :systemd ->
        cond do
          not ours?(run(opts, "systemctl", ["--user", "show", @unit, "-p", "Environment"])) ->
            :none

          match?({"active" <> _, 0}, run(opts, "systemctl", ["--user", "is-active", @unit])) ->
            :running

          match?({_, 0}, run(opts, "systemctl", ["--user", "is-enabled", @unit])) ->
            :stopped

          true ->
            :none
        end

      :none ->
        :none
    end
  end

  @doc "Asks the service to stop and start again. `:ok` or `{:error, why}`."
  def restart(opts \\ []) do
    case kind(opts) do
      :launchd ->
        case loaded(opts) do
          # The login item is kept alive, so launchd starts it again as
          # soon as it has stopped.
          {target, _} -> done(run(opts, "launchctl", ["kill", "SIGTERM", target]))
          nil -> {:error, "it is not set up as a login item"}
        end

      :systemd ->
        if state(opts) == :none,
          do: {:error, "it is not set up as a service"},
          else: done(run(opts, "systemctl", ["--user", "restart", @unit]))

      :none ->
        {:error, "this machine has no launchd or systemd"}
    end
  end

  @doc """
  Sets VitalAIze up as a systemd user service with the release's own
  systemd.sh, which also starts it. Linux only; a Mac's login item is the
  VitalAIze app's to install.
  """
  def install(opts \\ []) do
    script =
      Path.join(Keyword.get(opts, :root) || System.get_env("RELEASE_ROOT") || ".", "systemd.sh")

    cond do
      kind(opts) != :systemd -> {:error, "this needs systemd"}
      opts[:run] == nil and not File.regular?(script) -> {:error, "#{script} is missing"}
      true -> done(run(opts, script, ["on"]))
    end
  end

  # The login item that is loaded, as {its launchd name, what launchd
  # prints about it}.
  defp loaded(opts) do
    with {uid, 0} <- run(opts, "id", ["-u"]) do
      labels =
        case System.get_env("WALLBOARD_LABEL") do
          label when is_binary(label) and label != "" -> [label]
          _ -> @labels
        end

      Enum.find_value(labels, fn label ->
        target = "gui/#{String.trim(uid)}/#{label}"

        case run(opts, "launchctl", ["print", target]) do
          {out, 0} = printed -> if ours?(printed), do: {target, out}
          _ -> nil
        end
      end)
    else
      _ -> nil
    end
  end

  # Whether what launchd or systemd prints about a service names the
  # settings file being changed here.
  defp ours?({out, 0}) do
    case Regex.run(~r/WALLBOARD_SETTINGS(?: => |=)(.+?)(?: [A-Z_]+=|$)/m, out) do
      [_, path] -> Path.expand(String.trim(path)) == settings_file()
      _ -> false
    end
  end

  defp ours?(_), do: false

  # Where the settings file is looked for from here, there or not.
  defp settings_file do
    cond do
      path = env("WALLBOARD_SETTINGS") -> Path.expand(path)
      root = env("RELEASE_ROOT") -> Path.join(Path.expand(root), "settings.exs")
      true -> Path.join(File.cwd!(), "settings.exs")
    end
  end

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp done({_, 0}), do: :ok

  defp done({out, status}),
    do: {:error, out |> String.trim() |> String.slice(0, 300) |> or_status(status)}

  defp or_status("", status), do: "it answered #{status}"
  defp or_status(text, _), do: text

  defp tool?(name, opts), do: opts[:run] != nil or System.find_executable(name) != nil

  defp run(opts, program, args) do
    case opts[:run] do
      nil ->
        case System.find_executable(program) do
          nil -> {"#{program} is not installed", 127}
          exe -> System.cmd(exe, args, stderr_to_stdout: true)
        end

      run ->
        run.(program, args)
    end
  rescue
    e -> {Exception.message(e), 1}
  end
end
