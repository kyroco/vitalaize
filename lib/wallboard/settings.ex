defmodule Wallboard.Settings do
  @moduledoc """
  Loads the one settings file that holds everything site-specific.

  The file is plain Elixir that evaluates to a map (see settings.example.exs).
  It is looked for in this order:

    1. the path in the WALLBOARD_SETTINGS environment variable
    2. settings.exs in the release folder (RELEASE_ROOT)
    3. settings.exs in the current folder

  Anything the file leaves out falls back to the defaults below, so a friend
  only writes the parts that differ.

  On top of the file come the values saved from the settings page, kept in
  the board's database (see `editable/0`). The file stays the base: a value
  saved on the page wins until it is cleared there.
  """

  require Logger

  @key {__MODULE__, :settings}

  @defaults %{
    port: 4747,
    token: nil,
    rotate_seconds: 30,
    timezone: "America/New_York",
    brand: %{
      name: "Kyroco",
      logo: nil,
      page2_title: "Production health · New Relic"
    },
    claude: %{
      config_dirs: ["~/.claude"],
      poll_seconds: 5,
      long_running_minutes: 45
    },
    # Codex sessions, read from each folder's sessions/ files. A folder that
    # does not exist is skipped, so this can stay on without Codex installed.
    # A Codex session shows on the Live tab while it works, and for
    # `idle_minutes` after its last turn.
    codex: %{
      enabled: true,
      dirs: ["~/.codex"],
      idle_minutes: 120
    },
    alerts: %{
      phone: nil,
      # "iMessage", or "SMS" for a plain text sent through your iPhone (needs
      # Text Message Forwarding), which reaches numbers not on iMessage.
      via: "iMessage"
    },
    usage: %{
      poll_seconds: 30,
      # How far back to read transcripts. The trend compares the last 7 days
      # with activity against the 7 before them, so this needs some slack.
      days_back: 21,
      # API list prices in dollars per million tokens (checked 2026-09-28).
      # Cache writes are charged at 1.25x input (5-minute) or 2x (1-hour).
      # A model id matches the longest name here that it starts with.
      prices: %{
        "claude-fable-5-1" => %{
          label: "Fable 5.1",
          input: 10.0,
          output: 50.0,
          cache_read: 0.25,
          context: 1_000_000
        },
        "claude-fable-5" => %{
          label: "Fable 5",
          input: 10.0,
          output: 50.0,
          cache_read: 1.0,
          context: 1_000_000
        },
        "claude-opus-5-5" => %{
          label: "Opus 5.5",
          input: 4.0,
          output: 20.0,
          cache_read: 0.20,
          context: 1_000_000
        },
        "claude-opus-5" => %{
          label: "Opus 5",
          input: 5.0,
          output: 25.0,
          cache_read: 0.50,
          context: 1_000_000
        },
        "claude-opus-4" => %{
          label: "Opus 4",
          input: 5.0,
          output: 25.0,
          cache_read: 0.50,
          context: 1_000_000
        },
        "claude-sonnet-5-5" => %{
          label: "Sonnet 5.5",
          input: 2.0,
          output: 10.0,
          cache_read: 0.20,
          context: 1_000_000
        },
        "claude-sonnet-5" => %{
          label: "Sonnet 5",
          input: 2.0,
          output: 10.0,
          cache_read: 0.20,
          context: 1_000_000
        },
        "claude-sonnet-4-6" => %{
          label: "Sonnet 4.6",
          input: 3.0,
          output: 15.0,
          cache_read: 0.30,
          context: 1_000_000
        },
        "claude-haiku-4-5" => %{
          label: "Haiku 4.5",
          input: 1.0,
          output: 5.0,
          cache_read: 0.10,
          context: 200_000
        }
      }
    },
    github: %{
      repo: "your-org/your-repo",
      branch: "main",
      poll_seconds: 30,
      deploy_poll_seconds: 120,
      gate_workflow: "ci.yml",
      gate_check: "ci",
      dev_deploy: "deploy-staging.yml",
      prod_deploy: "deploy-production.yml",
      deploy_workflows: ["deploy-staging.yml", "deploy-production.yml"],
      lanes: [
        %{label: "CI", workflows: ["ci.yml"]},
        %{label: "Staging", workflows: ["deploy-staging.yml"]},
        %{label: "Production", workflows: ["deploy-production.yml"]}
      ]
    },
    dev_power: %{
      aws_profile: nil,
      region: nil,
      database: nil,
      cluster: nil,
      poll_seconds: 60
    },
    # Whether this team uses Korium. Off hides the Korium numbers.
    korium: %{enabled: true},
    # Once a day, ask GitHub for the latest release and show a note by
    # Settings when it is newer than this board.
    updates: %{check: true},
    archive: %{
      enabled: true,
      # Save this Mac's own Claude sessions. Off makes a hub that only keeps
      # what other Macs send.
      collect_local: true,
      # Announce the board on the local network, so a collector Mac finds it.
      advertise: true,
      # nil picks this system's usual place; see db_path/1.
      path: nil,
      machine: nil,
      backfill_days: 14,
      settle_seconds: 120,
      poll_seconds: 60,
      github_poll_seconds: 300,
      github_jobs_per_round: 100
    },
    builds: %{
      prod_profile: nil,
      dev_profile: nil,
      region: "us-east-1",
      repository: nil,
      dev: %{cluster: nil, services: []},
      prod: %{cluster: nil, services: []},
      poll_seconds: 60
    },
    new_relic: %{
      enabled: true,
      api_key_ref: nil,
      account_id: nil,
      region: "us",
      poll_seconds: 60,
      checks: [],
      slots: 3
    },
    theme: %{
      page: "#f1efed",
      surface: "#ffffff",
      text: "#1f1a17",
      text_body: "#6a625c",
      text_muted: "#746a61",
      border: "#e7e2dd",
      border_strong: "#d2cdc8",
      track: "#efe9e4",
      accent: "#e44456",
      alert: "#c13340",
      info: "#2e6b7c",
      info_light: "#7bb4c4",
      ok: "#16a34a",
      warn: "#f59e0b",
      warn_deep: "#b45309",
      # The dark look: the same names, warm dark grays. Each device picks
      # light or dark with the switch by Settings, or follows its own mode.
      # Text colors clear 4.5:1 on these surfaces.
      dark: %{
        page: "#161413",
        surface: "#211e1c",
        text: "#f3efeb",
        text_body: "#c9c1b9",
        text_muted: "#9a9087",
        border: "#34302c",
        border_strong: "#4a443e",
        track: "#2c2825",
        accent: "#f05a6b",
        alert: "#c13340",
        info: "#5fa3b8",
        info_light: "#3f6f7d",
        ok: "#34c46a",
        warn: "#f5b93b",
        warn_deep: "#f0a43a"
      },
      radius: "4px",
      font_body: "system-ui, -apple-system, sans-serif",
      font_display: "'Playfair Display', Georgia, serif",
      font_css_url:
        "https://fonts.googleapis.com/css2?family=Playfair+Display:wght@400;500&display=swap",
      fonts_dir: nil,
      font_faces: []
    }
  }

  def defaults, do: @defaults

  @doc "The loaded settings. Loads them on first use."
  def get do
    case :persistent_term.get(@key, nil) do
      nil -> load!()
      settings -> settings
    end
  end

  def get(key), do: Map.fetch!(get(), key)

  @doc "Reads the settings file, merges it over the defaults and caches it."
  def load! do
    settings =
      case path() do
        nil ->
          Logger.warning("No settings file found, using defaults. See settings.example.exs.")
          @defaults

        path ->
          {value, _binding} = Code.eval_file(path)

          unless is_map(value) do
            raise ArgumentError, "#{path} must evaluate to a map, like settings.example.exs"
          end

          Logger.info("Settings loaded from #{path}")
          merge(@defaults, value)
      end

    settings =
      settings
      |> merge(saved_overrides(settings))
      |> normalize()

    :persistent_term.put(@key, settings)
    settings
  end

  @doc "The settings from the defaults and the file alone, without the page's values."
  def base do
    case path() do
      nil ->
        normalize(@defaults)

      path ->
        {value, _} = Code.eval_file(path)
        @defaults |> merge(value) |> normalize()
    end
  end

  @doc """
  The settings a person can change on the settings page, in page order:
  {section, [{path, label, type, restart?, help}]}. Types: :string,
  :integer, :lines (a list, one per line), :secret, and {:choice, options}.
  `restart?` marks the few that only take effect when the board restarts.
  """
  def editable do
    [
      {"Board",
       [
         {[:brand, :name], "Board name", :string, false, nil},
         {[:rotate_seconds], "Seconds between pages", :integer, false,
          "0 stops the pages turning"},
         {[:timezone], "Time zone", :string, false, "Like America/New_York"},
         {[:token], "Board password", :secret, true,
          "Optional. With one, other devices need ?token= once, and can change settings"},
         {[:updates, :check], "Tell me when a new version is out", :boolean, false,
          "Checks GitHub once a day"}
       ]},
      {"What this board shows",
       [
         {[:korium, :enabled], "Korium numbers", :boolean, false,
          "Memory and code search hits, saves and indexing"},
         {[:new_relic, :enabled], "New Relic page", :boolean, true, nil},
         {[:archive, :collect_local], "Save this Mac's Claude sessions", :boolean, true,
          "Off for a hub that only keeps what other Macs send"}
       ]},
      {"Text alerts",
       [
         {[:alerts, :phone], "Phone number", :string, false, "Empty turns texts off"},
         {[:alerts, :via], "Send as", {:choice, ["iMessage", "SMS"]}, false, nil}
       ]},
      {"Claude",
       [
         {[:claude, :config_dirs], "Claude folders", :lines, false, "One per line"},
         {[:claude, :long_running_minutes], "Long-running after (minutes)", :integer, false, nil}
       ]},
      {"Codex",
       [
         {[:codex, :enabled], "Codex sessions", :boolean, false,
          "Show and save this Mac's Codex sessions"},
         {[:codex, :dirs], "Codex folders", :lines, false, "One per line"},
         {[:codex, :idle_minutes], "Keep an idle session on Live for (minutes)", :integer, false,
          nil}
       ]},
      {"GitHub",
       [
         {[:github, :repo], "Repository", :string, false, "owner/name"},
         {[:github, :branch], "Main branch", :string, false, nil},
         {[:github, :gate_workflow], "Gate workflow file", :string, false, nil},
         {[:github, :dev_deploy], "Dev deploy workflow file", :string, false, nil},
         {[:github, :prod_deploy], "Prod deploy workflow file", :string, false, nil}
       ]},
      {"AWS (read-only profiles)",
       [
         {[:dev_power, :aws_profile], "Dev profile", :string, true, "Shows dev awake or asleep"},
         {[:builds, :prod_profile], "Prod profile", :string, true,
          "Compares the builds dev and prod run"}
       ]},
      {"Archive",
       [
         {[:archive, :backfill_days], "Days to save on first start", :integer, false, nil},
         {[:archive, :settle_seconds], "Save a session after it is quiet for (seconds)", :integer,
          false, nil},
         {[:archive, :hub_url], "Address other Macs use", :string, false,
          "Empty uses this Mac's network address"}
       ]}
    ]
  end

  @doc """
  Types include :boolean (a checkbox). Checks the page's values (strings, keyed by path) against the base and
  returns {:ok, overrides} with only the values that differ from it, or
  {:error, %{path => message}}.
  """
  def check(values, base) do
    fields = for {_, fs} <- editable(), f <- fs, do: f

    Enum.reduce(fields, {%{}, %{}}, fn {path, label, type, _, _}, {over, errors} ->
      raw = Map.get(values, Enum.join(path, "."), "")

      case parse(type, raw, path) do
        {:ok, value} ->
          if value == get_in(base, path),
            do: {over, errors},
            else: {put_path(over, path, value), errors}

        {:error, msg} ->
          {over, Map.put(errors, Enum.join(path, "."), "#{label}: #{msg}")}
      end
    end)
    |> case do
      {over, errors} when errors == %{} -> {:ok, over}
      {_, errors} -> {:error, errors}
    end
  end

  defp parse(:boolean, raw, _path), do: {:ok, raw in ["true", "on"]}

  defp parse(:integer, raw, _path) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, "must be a whole number"}
    end
  end

  defp parse(:lines, raw, _path) do
    lines = raw |> String.split(~r/\R/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    {:ok, Enum.map(lines, &Path.expand/1)}
  end

  defp parse({:choice, options}, raw, _path) do
    if raw in options, do: {:ok, raw}, else: {:error, "pick one of #{Enum.join(options, ", ")}"}
  end

  defp parse(_type, raw, path) do
    value = String.trim(raw)

    cond do
      value == "" ->
        {:ok, nil}

      path == [:github, :repo] and not (value =~ ~r{^[\w.-]+/[\w.-]+$}) ->
        {:error, "use owner/name"}

      path in [[:dev_power, :aws_profile], [:builds, :prod_profile]] and
          not (value =~ ~r/^[\w.-]+$/) ->
        {:error, "use a profile name from ~/.aws/config"}

      path == [:archive, :hub_url] and not (value =~ ~r{^https?://[^\s/]+}) ->
        {:error, "use an address like http://192.168.1.20:4747"}

      true ->
        {:ok, value}
    end
  end

  defp put_path(map, [k], v), do: Map.put(map, k, v)
  defp put_path(map, [k | rest], v), do: Map.put(map, k, put_path(Map.get(map, k, %{}), rest, v))

  @doc "Saves the page's values in the database and reloads the settings."
  def save_overrides(overrides) do
    Wallboard.Store.put_meta("settings_overrides", Jason.encode!(overrides))
    load!()
  end

  # The page's saved values, read straight from the database file: the
  # settings are loaded before the database process starts.
  defp saved_overrides(settings) do
    path = settings |> get_in([:archive, :path]) |> db_path()

    with true <- File.regular?(path),
         {:ok, conn} <- Exqlite.Sqlite3.open(path, mode: :readonly) do
      try do
        with {:ok, stmt} <-
               Exqlite.Sqlite3.prepare(
                 conn,
                 "SELECT value FROM meta WHERE key = 'settings_overrides'"
               ),
             {:row, [json]} <- Exqlite.Sqlite3.step(conn, stmt),
             {:ok, %{} = map} <- Jason.decode(json) do
          atomize(map)
        else
          _ -> %{}
        end
      after
        Exqlite.Sqlite3.close(conn)
      end
    else
      _ -> %{}
    end
  end

  # Only the page's own keys become atoms, so a stored value can never make
  # new atoms.
  defp atomize(map) do
    for {_, fs} <- editable(), {path, _, _, _, _} <- fs, reduce: %{} do
      acc ->
        keys = Enum.map(path, &Atom.to_string/1)

        case get_in(map, keys) do
          nil -> if has_path?(map, keys), do: put_path(acc, path, nil), else: acc
          v -> put_path(acc, path, v)
        end
    end
  end

  defp has_path?(map, [k]), do: is_map(map) and Map.has_key?(map, k)
  defp has_path?(map, [k | rest]), do: is_map(map) and has_path?(Map.get(map, k), rest)

  @doc "Replaces the cached settings. Used by tests."
  def put(settings), do: :persistent_term.put(@key, merge(@defaults, settings) |> normalize())

  def path do
    [
      System.get_env("WALLBOARD_SETTINGS"),
      System.get_env("RELEASE_ROOT") && Path.join(System.get_env("RELEASE_ROOT"), "settings.exs"),
      Path.join(File.cwd!(), "settings.exs")
    ]
    |> Enum.find(&(&1 && File.regular?(&1)))
  end

  @doc "Deep merge, where the file's values win and lists replace lists."
  def merge(%{} = base, %{} = over) do
    Map.merge(base, over, fn
      _k, %{} = a, %{} = b -> merge(a, b)
      _k, _a, b -> b
    end)
  end

  @doc false
  def normalize(settings) do
    settings
    |> update_in([:claude, :config_dirs], fn dirs -> Enum.map(List.wrap(dirs), &Path.expand/1) end)
    |> update_in([:codex, :dirs], fn dirs -> Enum.map(List.wrap(dirs), &Path.expand/1) end)
    |> update_in([:alerts, :phone], &blank_to_nil/1)
    |> update_in([:token], &blank_to_nil/1)
    |> Map.update(:updates, @defaults.updates, &updates/1)
    |> update_in([:archive, :path], &db_path/1)
    |> update_in([:brand, :logo], fn
      nil -> nil
      "" -> nil
      logo -> Path.expand(logo)
    end)
  end

  @doc """
  Where the database lives: the setting when there is one, otherwise the
  usual place for app data on this system. On a Mac that is
  ~/Library/Application Support/Wallboard; on Linux, $XDG_DATA_HOME/vitalaize
  (~/.local/share/vitalaize when that is not set).
  """
  def db_path(path) when is_binary(path) and path != "", do: Path.expand(path)

  def db_path(_) do
    case :os.type() do
      {:unix, :darwin} ->
        Path.expand("~/Library/Application Support/Wallboard/wallboard.db")

      _ ->
        base =
          case System.get_env("XDG_DATA_HOME") do
            dir when is_binary(dir) and dir != "" -> dir
            _ -> Path.expand("~/.local/share")
          end

        Path.join([base, "vitalaize", "wallboard.db"])
    end
  end

  # The file may say `updates: false` or leave `check` out; the rest of the
  # board only ever sees %{check: true} or %{check: false}.
  defp updates(%{check: check}), do: %{check: check == true}
  defp updates(%{}), do: @defaults.updates
  defp updates(nil), do: @defaults.updates
  defp updates(_), do: %{check: false}

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank_to_nil(value), do: value

  @doc """
  The key that signs the browser session cookie. Derived from the token so it
  stays the same across restarts without being another thing to configure.
  """
  def secret_key_base(settings) do
    seed = settings.token || "wallboard-without-a-token"
    :crypto.hash(:sha512, "wallboard:" <> seed) |> Base.encode64()
  end
end
