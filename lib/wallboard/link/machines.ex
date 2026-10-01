defmodule Wallboard.Link.Machines do
  @moduledoc """
  The connected machines, as the settings page lists them: this hub first,
  then every machine that holds a working certificate (see
  `Wallboard.Link.Authority`), with what each said about itself in its last
  hello and how lately it sent anything.

  A machine's name is the one in its certificate. Its system and folders
  are only what it told the hub, shown and never acted on.
  """

  alias Wallboard.Link.{Authority, Hub}
  alias Wallboard.Store

  # A session counts as going on now when one of its files grew this lately.
  @now_seconds 600

  @doc """
  The list, for a hub with the link on. Each row is a map:

    * `name`, and `hub?` (true for this hub's own row, which has no Disconnect)
    * `os`: text, or nil when the machine has not said hello yet
    * `connected?`: its stream is open now
    * `seen_at`: when it last said or sent anything, in seconds since 1970, or nil
    * `sessions`: sessions that sent something in the last ten minutes
    * `folders`: the Claude and Codex folders it watches

  `local_sessions` is how many sessions this hub's own machine has now.
  """
  def list(settings, local_sessions \\ 0) do
    dir = Authority.dir(settings)
    now = System.os_time(:second)
    hellos = Map.new(Store.collector_machines(), &{&1.machine, &1})
    activity = Store.collector_activity(now - @now_seconds)
    connected = Hub.connected()

    others =
      for %{machine: name, revoked_at: nil} <- Authority.machines(dir), uniq: true do
        hello = hellos[name] || %{}
        live = connected[name]
        act = activity[name] || %{last: nil, sessions: 0}

        %{
          name: name,
          hub?: false,
          os: text(hello[:os]),
          connected?: live != nil,
          seen_at:
            [hello[:seen_at], act.last, live && live.since] |> Enum.filter(& &1) |> latest(),
          sessions: act.sessions,
          folders: for(f <- hello[:folders] || [], t = text(f), t != nil, do: t)
        }
      end

    [hub_row(settings, local_sessions, now) | Enum.sort_by(others, &String.downcase(&1.name))]
  end

  defp hub_row(settings, sessions, now) do
    folders =
      (get_in(settings, [:claude, :config_dirs]) || []) ++
        if(get_in(settings, [:codex, :enabled]) == false,
          do: [],
          else: get_in(settings, [:codex, :dirs]) || []
        )

    %{
      name: Wallboard.Archive.Collector.machine(settings),
      hub?: true,
      os: os_name(),
      connected?: true,
      seen_at: now,
      sessions: sessions,
      folders: Enum.map(folders, &short/1)
    }
  end

  defp latest([]), do: nil
  defp latest(times), do: Enum.max(times)

  @doc "This machine's system by name: `\"macOS\"`, `\"Linux\"`."
  def os_name do
    case :os.type() do
      {:unix, :darwin} -> "macOS"
      {:unix, :linux} -> "Linux"
      {_, name} -> to_string(name)
    end
  end

  # A folder under the home folder reads as ~/...
  defp short(path) do
    home = System.user_home()

    if is_binary(home) and String.starts_with?(path, home <> "/"),
      do: "~" <> String.replace_prefix(path, home, ""),
      else: path
  end

  # What a machine said about itself is shown on a page, so it is kept
  # short and to what can be printed.
  defp text(value) when is_binary(value) do
    if String.valid?(value) do
      case value |> String.replace(~r/[\p{C}]/u, "") |> String.slice(0, 120) do
        "" -> nil
        clean -> clean
      end
    end
  end

  defp text(_), do: nil
end
