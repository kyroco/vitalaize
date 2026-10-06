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

  On top of the file come the saved settings: what the VitalAIze app and
  `vitalaize setup` write (see `Wallboard.Setup`). They share one file,
  settings.json, so either can change what the other saved. It sits beside
  settings.exs (see `saved_path/0`) and holds only the values in
  `editable/0` that differ from what is under them. The file stays the
  base: settings.exs alone, with no settings.json, loads as it always did.

  Boards from before settings.json kept the values saved on the settings
  page in their database. Those still load, between the file and
  settings.json, so a board updated in place keeps them.
  """

  require Logger

  @key {__MODULE__, :settings}

  @roles %{"hub" => :hub, "collector" => :collector, "both" => :both}

  # The workflows a repository can name for itself on a form, and the word
  # for each there.
  @repo_words [gate_workflow: "gate", dev_deploy: "dev", prod_deploy: "prod"]
  @repo_keys Keyword.keys(@repo_words)

  # The fields a form has for the first repository's workflows, as it
  # names them.
  @first_repo_fields Enum.map(@repo_keys, &"github.#{&1}")

  # A workflow file as a form takes it: a name like ci.yml, never a path
  # and never "." or "..".
  @workflow_file ~r/\A\w[\w.-]*\z/

  # What a repository that names no workflows has.
  @no_workflows %{
    gate_workflow: nil,
    dev_deploy: nil,
    prod_deploy: nil,
    deploy_workflows: [],
    lanes: []
  }

  @defaults %{
    # What this machine does:
    #   "both"       runs the board and saves this machine's own sessions
    #   "hub"        runs the board and saves only what other machines send
    #   "collector"  runs no board: it watches this machine's sessions for a
    #                hub (see Wallboard.Collector.Watcher)
    # The WALLBOARD_ROLE environment variable, when set, wins over the file.
    role: "both",
    # Only read in the collector role.
    collector: %{
      # nil finds them: ~/.claude and every ~/.claude-something that holds
      # sessions, and ~/.codex. A list here is used as written.
      claude_dirs: nil,
      codex_dirs: nil,
      # Where the collector keeps its place and its unsent events. nil picks
      # a "collector" folder beside the database's usual place.
      dir: nil,
      # The most the unsent events may take on disk, in megabytes.
      outbox_mb: 64,
      # On the first start, sessions that changed in this many days are
      # reported. An older one is reported once it changes again.
      backfill_days: 14,
      # How often to look for new lines in the session files.
      poll_seconds: 2
    },
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
      via: "iMessage",
      # Alerts that work without a Mac. Each one that is set gets every alert.
      # A Slack incoming webhook address (https://hooks.slack.com/...).
      slack_webhook: nil,
      # An ntfy topic. Anyone who knows it can read it, so make it hard to
      # guess. nil for ntfy_server means https://ntfy.sh.
      ntfy_topic: nil,
      ntfy_server: nil,
      # Your Pushover user key and the API token of an app you made there.
      pushover_user: nil,
      pushover_token: nil
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
    # The repositories are listed in `repos`; an entry there can be a map
    # that changes any of this for that one repository. The workflow files
    # named here (the gate, the deploys and the timeline rows) are the first
    # repository's: another repository names its own in its entry, or has
    # none. With `repos` empty the board follows `repo` alone, as files from
    # before several repositories do.
    github: %{
      repos: [],
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
    # The link: collectors on other machines stream their sessions to this
    # hub over gRPC, encrypted, with a certificate on both ends (see
    # Wallboard.Link). Off until turned on; it needs the archive, since
    # that is where the sessions go. The port is its own, not the board's.
    link: %{
      enabled: false,
      port: 4748
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
      # A key typed in the app or in `vitalaize setup` is kept in the
      # keychain or a file only you can read (see Wallboard.KeyStore). Here
      # is only a note that it is kept and when it was saved, written by
      # those saves. With none, api_key_ref is used.
      api_key: nil,
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

  @doc """
  Reads the settings file and the saved settings, lays them over the
  defaults and caches the result.
  """
  def load! do
    settings = read!()
    :persistent_term.put(@key, settings)
    settings
  end

  @doc """
  Loads the settings again under a board or collector that is running,
  for `Wallboard.Settings.Watch`. Every setting that is only read at the
  start (`editable/0` marks those: the role, the ports, the board
  password and the rest) keeps the value in use. Those change when
  VitalAIze starts, never under it, so a settings file that goes missing
  cannot take the password off a board that is still running.

  Returns `{in_use, read, now}`: the settings before, the ones just read,
  and the ones in use from here on.
  """
  def reload! do
    in_use = get()
    read = read!()

    now =
      for {_, fields} <- editable(), {path, _, _, true, _} <- fields, reduce: read do
        acc -> put_in(acc, path, get_in(in_use, path))
      end

    :persistent_term.put(@key, now)
    {in_use, read, now}
  end

  # The settings as the files give them, cached nowhere.
  defp read! do
    saved = read_saved!()

    file =
      case path() do
        nil ->
          if saved == %{},
            do:
              Logger.warning("No settings file found, using defaults. See settings.example.exs.")

          @defaults

        path ->
          Logger.info("Settings loaded from #{path}")
          file!(path)
      end

    file |> layers(saved) |> normalize()
  end

  defp file!(path) do
    {value, _binding} = Code.eval_file(path)

    unless is_map(value) do
      raise ArgumentError, "#{path} must evaluate to a map, like settings.example.exs"
    end

    merge(@defaults, value)
  end

  # The file, then what an older board's settings page saved in the
  # database, then the saved settings. A collector has no database, and the
  # role is known only once the saved settings are on, so it is worked out
  # first. WALLBOARD_ROLE wins over all of them.
  defp layers(file, saved) do
    probe = file |> apply_overrides(saved) |> env_role()

    if role(probe) == :collector,
      do: probe,
      else:
        file
        |> apply_overrides(saved_overrides(probe))
        |> apply_overrides(saved)
        |> env_role()
  end

  @doc "The settings from the defaults and the file alone, with nothing saved on top."
  def base do
    case path() do
      nil -> @defaults |> env_role() |> normalize()
      path -> path |> file!() |> env_role() |> normalize()
    end
  end

  @doc """
  The settings as they would be with no settings.json: the defaults, the
  file and what an older settings page saved. The saved settings hold only
  what differs from this.
  """
  def under_saved, do: under_saved(nil)

  @doc """
  `under_saved/0` worked out as a machine in `role` would see it. The role
  shapes other settings (a hub never saves its own sessions), so a value
  is compared with what is under it in the role that will be in effect.
  nil is the file's own role.
  """
  def under_saved(role) do
    file = if path = path(), do: file!(path), else: @defaults
    # The role decides whether there is a database of older values to
    # read, so the layers are worked out in the role asked for, not the
    # one saved now: a save that changes the role must see what will be
    # under its values once that role is in effect.
    chosen = if role, do: %{role: role}, else: %{}
    file |> layers(chosen) |> Map.put(:role, role || env_role(file).role) |> normalize()
  end

  @doc """
  Where the saved settings live: the path in WALLBOARD_SAVED_SETTINGS, or
  settings.json beside the settings file (see `file_place/0`).
  """
  def saved_path do
    case System.get_env("WALLBOARD_SAVED_SETTINGS") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> file_place() |> Path.dirname() |> saved_in()
    end
  end

  @doc """
  The settings file this machine uses: the one `path/0` finds or, when
  there is none, the first place it would be looked for. The saved
  settings sit beside it, and a service belongs to these settings when it
  was started with this file (see `Wallboard.Setup.Service`).
  """
  def file_place, do: path() || List.first(places()) || Path.expand("~/settings.exs")

  defp saved_in(dir), do: Path.join(dir, "settings.json")

  # The saved settings as a map with atom keys, empty when there is no
  # file. A file that cannot be read stops the load: starting without it
  # could start the wrong role.
  defp read_saved! do
    path = saved_path()

    case File.read(path) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{} = map} -> atomize(map)
          _ -> raise ArgumentError, "#{path} is not a JSON object. Fix it, or delete it."
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        raise ArgumentError, "#{path} cannot be read: #{:file.format_error(reason)}"
    end
  end

  @doc """
  Lays the given values (text, keyed by path, like `"alerts.phone"`) over
  the saved settings and returns `{:ok, saved}` to hand to `save!/1`, or
  `{:error, %{path => message}}`.

  Only the fields given are looked at. A value that is the same as what
  is under the saved settings is taken out of them; any other is put in.
  The other saved settings stay as they are, and nothing the settings
  file holds is checked or copied, so a value there that this form would
  not take never stands in the way of a save. A secret given as `kept/0`
  (the dots) is left alone.

  "Under" is worked out in the role that will be in effect after this
  save (`under_saved/1`), since the role shapes other settings; the role
  itself is compared with the file's. The gate and deploy workflow fields
  are the first repository's, so they are compared with what is under the
  saved settings for the repository this save leaves first.
  """
  def change(values) do
    saved = read_saved!()
    fields = for {_, fs} <- editable(), f <- fs, into: %{}, do: {Enum.join(elem(f, 0), "."), f}

    role =
      case {parse({:choice, Map.keys(@roles)}, Map.get(values, "role", ""), [:role]), saved} do
        {{:ok, role}, _} -> role
        {_, %{role: role}} when is_binary(role) -> role
        _ -> nil
      end

    under_file = under_saved(nil)
    under = if role, do: under_saved(role), else: under_file

    # The gate and deploy fields are the first repository's, and which one
    # is first follows from the list this save leaves. So they are looked
    # at last, against the settings with that list in place.
    values
    |> Enum.sort_by(fn {key, _} -> key in @first_repo_fields end)
    |> Enum.reduce({saved, %{}}, fn {key, raw}, {saved, errors} ->
      case fields[key] do
        nil ->
          {saved, Map.put(errors, key, "#{key} is not a setting")}

        {path, label, type, _, _} ->
          case if(type in [:secret, :key] and raw == kept(),
                 do: :kept,
                 else: parse(type, raw, path)
               ) do
            :kept ->
              {saved, errors}

            {:ok, value} ->
              base =
                cond do
                  path == [:role] -> under_file
                  key in @first_repo_fields -> with_saved_repos(under, saved)
                  true -> under
                end

              if value == current(base, path, type),
                do: {drop_path(saved, path), errors},
                else: {put_path(saved, path, plain_repos(path, value, under)), errors}

            {:error, msg} ->
              {saved, Map.put(errors, key, "#{label}: #{msg}")}
          end
      end
    end)
    |> case do
      {saved, errors} when errors == %{} -> {:ok, saved}
      {_, errors} -> {:error, errors}
    end
  end

  # What is under the saved settings, with the saved list of repositories
  # laid over it: the first repository there is the one the gate and deploy
  # fields are for.
  defp with_saved_repos(under, %{github: %{repos: repos}}) when is_list(repos),
    do: apply_overrides(under, %{github: %{repos: repos}})

  defp with_saved_repos(under, _saved), do: under

  # A repository whose workflows are the same as the settings file gives it
  # is saved by name alone, so it goes on following the file when the file
  # changes (see keep_repo_details/2).
  defp plain_repos([:github, :repos], entries, under) do
    same = MapSet.new(repo_fields(under))

    Enum.map(entries, fn
      %{repo: name} = entry -> if MapSet.member?(same, entry), do: name, else: entry
      name -> name
    end)
  end

  defp plain_repos(_path, value, _under), do: value

  @doc """
  Takes the given keys out of the saved settings, so those settings follow
  the settings file again. Only settings.json is read and written: the
  settings file is not loaded and nothing is loaded again, so this works
  beside a settings file that does not load. No value is read or checked,
  so it cannot fail on one; a key that is not a setting is passed over.
  With nothing to take out, the file is left as it is, or not there.
  """
  def forget!(keys) do
    fields =
      for {_, fs} <- editable(),
          {path, _, _, _, _} <- fs,
          into: %{},
          do: {Enum.join(path, "."), path}

    saved = read_saved!()

    left =
      Enum.reduce(keys, saved, fn key, acc ->
        case fields[key] do
          nil -> acc
          path -> drop_path(acc, path)
        end
      end)

    if left != saved, do: write_saved!(left)
    :ok
  end

  # Takes a value out, and with it any map left empty above it.
  defp drop_path(map, [k]), do: Map.delete(map, k)

  defp drop_path(map, [k | rest]) do
    case Map.get(map, k) do
      %{} = inner ->
        case drop_path(inner, rest) do
          empty when empty == %{} -> Map.delete(map, k)
          left -> Map.put(map, k, left)
        end

      _ ->
        map
    end
  end

  @doc """
  Writes the saved settings (what `change/2` returned) and reloads. Only this user can read the file: it may
  hold the board password and alert keys. A key typed in goes to the key
  store first (`keep_keys/1`); raises when it cannot be kept, with nothing
  written.
  """
  def save!(overrides) do
    case keep_keys(overrides) do
      {:ok, overrides} ->
        write_saved!(overrides)
        load!()

      {:error, errors} ->
        raise ArgumentError, errors |> Map.values() |> Enum.join(" ")
    end
  end

  # The settings kept in the key store (`Wallboard.KeyStore`), and the
  # name each is kept under there.
  @kept_keys [{[:new_relic, :api_key], "new_relic"}]

  @doc """
  Puts each key typed in a save (what `change/1` returned) in the key
  store, and a note in its place in the saved settings: where it is kept
  and when it was saved, never the key. A key emptied in the save is taken
  out of the store. The note changing is what tells a running board to
  read the key again (`Wallboard.Settings.Watch`).

  Returns `{:ok, saved}` to hand to `save!/1`, or `{:error, %{path =>
  message}}` when the store would not take a key or let one go.
  """
  def keep_keys(saved) do
    before = read_saved!()

    Enum.reduce_while(@kept_keys, {:ok, saved}, fn {path, name}, {:ok, acc} ->
      field = Enum.join(path, ".")
      label = label(path)

      case {saved_at(acc, path), saved_at(before, path)} do
        {{:store, typed}, _} ->
          case Wallboard.KeyStore.put(name, typed.()) do
            :ok ->
              {:cont, {:ok, put_path(acc, path, key_note())}}

            {:error, why} ->
              {:halt,
               {:error,
                %{
                  field => "#{label}: could not be kept in #{Wallboard.KeyStore.place()} (#{why})"
                }}}
          end

        {nil, %{}} ->
          case Wallboard.KeyStore.delete(name) do
            :ok ->
              {:cont, {:ok, acc}}

            {:error, why} ->
              {:halt,
               {:error,
                %{
                  field =>
                    "#{label}: could not be taken out of #{Wallboard.KeyStore.place()} (#{why})"
                }}}
          end

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  @doc "The name a setting's key is kept under in the key store, or nil."
  def key_name(path), do: Enum.find_value(@kept_keys, fn {p, name} -> p == path && name end)

  @doc "Every setting kept in the key store, as `{name, label}`."
  def kept_keys, do: for({path, name} <- @kept_keys, do: {name, label(path)})

  defp saved_at(map, [k | rest]) do
    case map do
      %{^k => inner} when rest == [] -> inner
      %{^k => %{} = inner} -> saved_at(inner, rest)
      _ -> nil
    end
  end

  # String keys, as the note reads back from settings.json, so a note just
  # written and one read again are the same.
  defp key_note do
    %{
      "kept_in" => Wallboard.KeyStore.place(),
      "saved_at" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    }
  end

  defp label(path) do
    Enum.find_value(editable(), fn {_, fs} ->
      Enum.find_value(fs, fn {p, label, _, _, _} -> p == path && label end)
    end)
  end

  # Writes the saved settings and nothing else: the settings file is not
  # read and nothing is loaded again.
  defp write_saved!(overrides) do
    path = saved_path()
    File.mkdir_p!(Path.dirname(path))
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, "")
    File.chmod!(tmp, 0o600)
    File.write!(tmp, Jason.encode_to_iodata!(overrides, pretty: true))
    File.rename!(tmp, path)
    :ok
  end

  @doc """
  The role in a settings map, as :hub, :collector or :both. Raises on
  anything else, so a misspelled role never starts the wrong thing.
  """
  def role(%{role: role}) when role in [:hub, :collector, :both], do: role

  def role(%{role: role}) do
    case is_binary(role) && Map.fetch(@roles, String.trim(role)) do
      {:ok, role} ->
        role

      _ ->
        raise ArgumentError,
              ~s(role must be "hub", "collector" or "both", not #{inspect(role)})
    end
  end

  defp env_role(settings) do
    case System.get_env("WALLBOARD_ROLE") do
      role when is_binary(role) and role != "" -> Map.put(settings, :role, role)
      _ -> settings
    end
  end

  @doc """
  The settings a person can change on the settings page, in page order:
  {section, [{path, label, type, restart?, help}]}. Types: :string,
  :integer, :lines (a list, one per line), :secret, :key (a secret kept in
  the key store, not in the settings, see `keep_keys/1`), and
  {:choice, options}.
  `restart?` marks the few that only take effect when the board restarts.
  """
  def editable do
    [
      {"This machine",
       [
         {[:role], "What this machine does", {:choice, ["both", "hub", "collector"]}, true,
          "both runs the board and saves this machine's own sessions. hub runs the board " <>
            "only. collector runs no board: it watches this machine for a hub"}
       ]},
      {"Board",
       [
         {[:brand, :name], "Board name", :string, false, nil},
         {[:port], "Board port", :port, true, nil},
         {[:rotate_seconds], "Seconds between pages", :integer, false,
          "0 stops the pages turning"},
         {[:timezone], "Time zone", :string, false, "Like America/New_York"},
         {[:token], "Board password", :secret, true,
          "Optional. With one, other devices need ?token= once"},
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
      {"Alerts",
       [
         {[:alerts, :phone], "Phone number (Messages)", :string, false,
          "Mac only. Empty turns texts off"},
         {[:alerts, :via], "Send as", {:choice, ["iMessage", "SMS"]}, false, nil},
         {[:alerts, :slack_webhook], "Slack webhook", :secret, false,
          "An incoming webhook address. Empty turns Slack off"},
         {[:alerts, :ntfy_topic], "ntfy topic", :secret, false,
          "Hard to guess, since anyone with it can read it. Empty turns ntfy off"},
         {[:alerts, :ntfy_server], "ntfy server", :string, false, "Empty uses https://ntfy.sh"},
         {[:alerts, :pushover_user], "Pushover user key", :secret, false, nil},
         {[:alerts, :pushover_token], "Pushover app token", :secret, false,
          "Both Pushover fields are needed"}
       ]},
      {"New Relic",
       [
         {[:new_relic, :account_id], "Account number", :string, false, nil},
         {[:new_relic, :api_key], "New Relic API key", :key, false,
          "Paste the User key (it starts with NRAK-). Kept in your keychain on a Mac, in a " <>
            "file only you can read on Linux. Type a new one to replace it; empty the field " <>
            "to remove it"},
         {[:new_relic, :api_key_ref], "Or where it is in 1Password", :string, false,
          "An op:// address, read with 1Password's op command. Used when no key is typed above"},
         {[:new_relic, :region], "Region", {:choice, ["us", "eu"]}, false, nil}
       ]},
      {"Collectors on other machines",
       [
         {[:link, :enabled], "Take collectors", :boolean, true,
          "Other machines stream their sessions here once you approve them in the mailbox"},
         {[:link, :port], "Port they stream to", :port, true, "Its own port, not the board's"}
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
         {[:github, :repos], "Repositories", :repos, false,
          "owner/name, one per line. Dev and Prod follow the first one, and the workflow " <>
            "files below are its own. Another repository can name its own after its name: " <>
            "owner/name gate=ci.yml dev=deploy-dev.yml prod=deploy.yml"},
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
          false, nil}
       ]},
      {"Collector",
       [
         {[:collector, :claude_dirs], "Claude folders to watch", :folders, false,
          "One per line. Empty finds ~/.claude and every ~/.claude-something"},
         {[:collector, :codex_dirs], "Codex folders to watch", :folders, false,
          "One per line. Empty finds ~/.codex"}
       ]}
    ]
  end

  @doc """
  The part of `editable/0` a machine in this role uses. A collector has
  its own few settings and none of the board's; a board has no use for a
  collector's.
  """
  def editable(role) do
    Enum.filter(editable(), fn {section, _} ->
      section == "This machine" or section == "Collector" == (role == :collector)
    end)
  end

  @doc """
  Which part of a machine a setting belongs to: `:machine` (its role),
  `:collector` (which sessions on this machine are watched) or `:hub`
  (the board and everything it shows).
  """
  def part([:role]), do: :machine
  def part([:collector | _]), do: :collector
  def part([:claude, :config_dirs]), do: :collector
  def part([:codex, :dirs]), do: :collector
  def part([:codex, :enabled]), do: :collector
  def part([:archive, :collect_local]), do: :collector
  def part(_), do: :hub

  @kept "••••••••"

  @doc """
  The settings as text, keyed by path ("alerts.phone"), the way a form
  shows them. A secret that is set (a webhook address, a key, the board
  password) comes out as dots, never as itself.
  """
  def shown(settings) do
    for {_, fs} <- editable(), {path, _, type, _, _} <- fs, into: %{} do
      value = current(settings, path, type)
      text = if type in [:secret, :key] and value != nil, do: @kept, else: to_text(type, value)
      {Enum.join(path, "."), text}
    end
  end

  @doc """
  Turns a secret that came back as dots into the value it stands for now.
  `shown` is the settings the form was drawn from: only a secret that was
  set there went out as dots, so dots typed into an empty field are kept
  as typed, and dots from a form drawn before the secret changed elsewhere
  follow the newest value.
  """
  def unmask(values, shown, current) do
    for {_, fs} <- editable(), {path, _, :secret, _, _} <- fs, reduce: values do
      acc ->
        key = Enum.join(path, ".")

        if Map.get(acc, key) == @kept and get_in(shown, path) != nil,
          do: Map.put(acc, key, to_text(:secret, get_in(current, path))),
          else: acc
    end
  end

  defp to_text(_, nil), do: ""

  defp to_text(:repos, list), do: Enum.map_join(List.wrap(list), "\n", &repo_line/1)

  defp to_text(type, list) when type in [:lines, :folders],
    do: Enum.join(List.wrap(list), "\n")

  defp to_text(_, v), do: to_string(v)

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
          if value == current(base, path, type),
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

  @doc "Checks one field's text by itself: `:ok`, or `{:error, message}`."
  def check_one({path, _label, type, _restart, _help}, raw) do
    with {:ok, _} <- parse(type, raw, path), do: :ok
  end

  @doc "What `shown/1` puts in place of a secret that is set."
  def kept, do: @kept

  @doc """
  A field's value as the settings page shows it: each repository by name,
  or as a map when it names workflows of its own.
  """
  def current(settings, [:github, :repos], :repos), do: repo_fields(settings)

  # The workflow fields are the first repository's, so they show what is in
  # use for it: its own entry's where a settings file gives it one.
  def current(settings, [:github, key] = path, _type) when key in @repo_keys do
    case github_repos(settings) do
      [first | _] -> first[key]
      [] -> get_in(settings, path)
    end
  end

  def current(%{role: _} = settings, [:role], _type), do: settings |> role() |> Atom.to_string()
  def current(settings, path, _type), do: get_in(settings, path)

  defp parse(:boolean, raw, _path), do: {:ok, raw in ["true", "on"]}

  defp parse(:repos, raw, _path) do
    with {:ok, entries} <- parse_repos(raw) do
      case Enum.uniq_by(entries, & &1.repo) do
        # The first repository's workflows have fields of their own.
        [%{repo: name} = first | _] when map_size(first) > 1 ->
          {:error,
           "#{name} is the first repository: its workflows are the gate, dev deploy and " <>
             "prod deploy settings. Write gate=, dev= or prod= only after another repository"}

        entries ->
          {:ok,
           Enum.map(entries, fn entry ->
             if map_size(entry) == 1, do: entry.repo, else: entry
           end)}
      end
    end
  end

  defp parse(:integer, raw, _path) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, "must be a whole number"}
    end
  end

  defp parse(:port, raw, _path) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} when n >= 1 and n <= 65_535 -> {:ok, n}
      _ -> {:error, "must be a port number, 1 to 65535"}
    end
  end

  # nil, not an empty list: with none named, the collector finds them.
  defp parse(:folders, raw, path) do
    case parse(:lines, raw, path) do
      {:ok, []} -> {:ok, nil}
      other -> other
    end
  end

  defp parse(:lines, raw, _path) do
    lines = raw |> String.split(~r/\R/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    {:ok, Enum.map(lines, &Path.expand/1)}
  end

  defp parse({:choice, options}, raw, _path) do
    if raw in options, do: {:ok, raw}, else: {:error, "pick one of #{Enum.join(options, ", ")}"}
  end

  # A key for the key store. It is held inside a function until it is
  # kept, so printing what a save holds never shows it (see keep_keys/1).
  # No message here repeats what was typed.
  defp parse(:key, raw, _path) do
    value = String.trim(raw)

    cond do
      value == "" ->
        {:ok, nil}

      String.starts_with?(value, "op://") ->
        {:error, "that is a 1Password address: put it in Or where it is in 1Password"}

      not (value =~ ~r/\A[\w.\-]{8,256}\z/) ->
        {:error, "use the key exactly as New Relic shows it"}

      true ->
        {:ok, {:store, fn -> value end}}
    end
  end

  defp parse(_type, raw, path) do
    value = String.trim(raw)

    cond do
      value == "" ->
        {:ok, nil}

      path in [[:dev_power, :aws_profile], [:builds, :prod_profile]] and
          not (value =~ ~r/^[\w.-]+$/) ->
        {:error, "use a profile name from ~/.aws/config"}

      path == [:new_relic, :api_key_ref] and not String.starts_with?(value, "op://") ->
        {:error,
         "use the op:// address from 1Password. To give the key itself, put it in New Relic API key"}

      path == [:alerts, :slack_webhook] and not (value =~ ~r{^https://\S+$}) ->
        {:error, "use the https:// address Slack gave you"}

      path == [:alerts, :ntfy_topic] and not (value =~ ~r/^[\w-]{1,64}$/) ->
        {:error, "use letters, numbers, - and _ only"}

      path == [:alerts, :ntfy_server] and not (value =~ ~r{^https?://[^\s/?#]+(/[^\s?#]*)?$}) ->
        {:error, "use an address like https://ntfy.sh"}

      path in [[:alerts, :pushover_user], [:alerts, :pushover_token]] and
          not (value =~ ~r/^\w+$/) ->
        {:error, "use the key exactly as Pushover shows it"}

      true ->
        {:ok, value}
    end
  end

  defp put_path(map, [k], v), do: Map.put(map, k, v)
  defp put_path(map, [k | rest], v), do: Map.put(map, k, put_path(Map.get(map, k, %{}), rest, v))

  @doc """
  Adds a repository to the end of the list the board follows, and takes
  the new list up at once. This is the one setting the board itself
  saves: its owner said Track in the mailbox (`Wallboard.RepoPrompts`).
  The list goes into the saved settings (settings.json) the way a save
  from the VitalAIze app does, so it is still there after a restart and
  the app or `vitalaize setup` can change it later.

  `:ok`, also when the board follows it already. `{:error, :not_a_repo}`
  when the name is not owner/name. `{:error, :unreadable}` when the
  settings cannot be read (the saved settings are left as they are), and
  `{:error, :unavailable}` when they cannot be written.
  """
  def track_repo(name) do
    # The example name a board with no repositories set starts with is not
    # one to keep in front of a real one.
    settings = get()
    names = repo_names(settings) -- [@defaults.github.repo]

    cond do
      not repo_name?(name) or Enum.any?(String.split(name, "/"), &(&1 in [".", ".."])) ->
        {:error, :not_a_repo}

      Enum.any?(names, &(String.downcase(&1) == String.downcase(name))) ->
        :ok

      true ->
        # As the form shows them, so a repository keeps the workflows it names.
        fields =
          settings |> repo_fields() |> Enum.reject(&(repo_line(&1) == @defaults.github.repo))

        # With the example gone, the one now first is a name alone, and the
        # workflows it named go where the first repository's are kept: the
        # gate and deploy fields.
        {fields, own} =
          case fields do
            [%{repo: first} = entry | rest] -> {[first | rest], Map.delete(entry, :repo)}
            fields -> {fields, %{}}
          end

        lines = Enum.map(fields, &repo_line/1) ++ [name]

        for {key, file} <- own, into: %{"github.repos" => Enum.join(lines, "\n")} do
          {"github.#{key}", file || ""}
        end
        |> save_repos()
    end
  end

  defp save_repos(values) do
    with {:ok, saved} <- change(values) do
      write_saved!(saved)
      # The board is running: what is only read at the start stays.
      reload!()
      :ok
    else
      {:error, _} -> {:error, :not_a_repo}
    end
  rescue
    # Our own errors say the settings cannot be read (see read_saved!/0).
    ArgumentError -> {:error, :unreadable}
    _ -> {:error, :unavailable}
  end

  # What an older board's settings page saved, read straight from the
  # database file: the settings are loaded before the database process
  # starts. Nothing writes these any more.
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
  @doc false
  def atomize(map) do
    for {_, fs} <- editable(), {path, _, _, _, _} <- fs, reduce: legacy_repo(map) do
      acc ->
        keys = Enum.map(path, &Atom.to_string/1)

        case get_in(map, keys) do
          nil -> if has_path?(map, keys), do: put_path(acc, path, nil), else: acc
          v -> put_path(acc, path, saved_value(path, v))
        end
    end
  end

  # A repository saved with workflows of its own is a map; only the keys a
  # form can give it are read.
  defp saved_value([:github, :repos], list) when is_list(list) do
    Enum.map(list, fn
      %{"repo" => name} = entry when is_binary(name) ->
        for key <- @repo_keys, text = Atom.to_string(key), is_map_key(entry, text), into: %{} do
          {key, if(is_binary(entry[text]), do: entry[text])}
        end
        |> Map.put(:repo, name)

      other ->
        other
    end)
  end

  defp saved_value(_path, value), do: value

  # Before several repositories, the page saved one as github.repo. It stays
  # that, so a board updated in place keeps following it just as before: it
  # stands in for the file's `repo`, and a file that lists `repos` wins. The
  # page shows it, and saving the page turns it into the list.
  defp legacy_repo(%{"github" => %{"repo" => repo}}) when is_binary(repo) do
    if repo_name?(repo), do: %{github: %{repo: repo}}, else: %{}
  end

  defp legacy_repo(_), do: %{}

  @doc """
  Lays the settings page's saved values over the file's. The page saves
  a repository by name, or with the workflows it names; one the file
  describes with a map of its own settings keeps the rest of them.
  """
  def apply_overrides(file, overrides),
    do: file |> merge(overrides) |> keep_repo_details(file) |> first_repo_fields(overrides)

  # A form shows the first repository's gate and deploys as the three
  # workflow fields. When one of those was saved, it is the first
  # repository's, also where the file's entry for it names its own.
  defp first_repo_fields(settings, overrides) do
    set = Enum.filter(@repo_keys, &has_path?(overrides, [:github, &1]))

    update_in(settings, [:github, :repos], fn
      [%{} = first | rest] when set != [] -> [Map.drop(first, set) | rest]
      repos -> repos
    end)
  end

  defp keep_repo_details(settings, file) do
    details =
      for %{repo: name} = entry when is_binary(name) <- List.wrap(get_in(file, [:github, :repos])),
          into: %{},
          do: {String.trim(name), entry}

    # A name alone takes the file's entry as it is. One with workflows of
    # its own, as a map or as a line ("owner/name gate=ci.yml"), is laid
    # over the file's entry, which keeps the rest of what the file gave it.
    update_in(settings, [:github, :repos], fn repos ->
      Enum.map(List.wrap(repos), fn raw ->
        case repo_entry(raw) do
          %{repo: name} = entry when is_binary(raw) and map_size(entry) == 1 ->
            Map.get(details, name, raw)

          %{repo: name} = entry ->
            merge(Map.get(details, name, %{}), entry)

          nil ->
            raw
        end
      end)
    end)
  end

  @doc """
  Every repository the board follows, in settings order, each as the full
  GitHub settings for it: the shared ones with that entry's own laid over
  them. The first is the one Dev and Prod read. With `repos` empty it is
  `repo` alone.

  The workflow files in the shared settings (`gate_workflow`, `dev_deploy`,
  `prod_deploy`, `deploy_workflows` and `lanes`) are the first repository's
  alone. Another repository has only the ones its own entry names, and its
  timeline rows and deploy list follow from those unless it lists them.
  """
  def github_repos(settings) do
    shared = Map.drop(settings.github, [:repos])
    bare = Map.merge(shared, @no_workflows)

    settings.github
    |> repo_entries()
    |> Enum.map(&repo_entry/1)
    |> Enum.filter(&(&1 && repo_name?(&1.repo)))
    |> Enum.uniq_by(& &1.repo)
    |> Enum.with_index()
    |> Enum.map(fn
      {entry, 0} -> merge(shared, entry)
      {entry, _} -> bare |> merge(entry) |> own_rows(entry)
    end)
  end

  # The deploy list and the timeline rows of a repository that names its
  # workflows but lists neither.
  defp own_rows(gh, entry) do
    gh
    |> Map.put(
      :deploy_workflows,
      entry[:deploy_workflows] || Enum.reject([gh.dev_deploy, gh.prod_deploy], &is_nil/1)
    )
    |> Map.put(
      :lanes,
      entry[:lanes] ||
        for(
          {label, file} when is_binary(file) <- [
            {"Gate", gh.gate_workflow},
            {"Dev deploy", gh.dev_deploy},
            {"Prod", gh.prod_deploy}
          ],
          do: %{label: label, workflows: [file]}
        )
    )
  end

  # One entry of `repos` as a map with its trimmed name, or nil. A name can
  # carry workflows of its own the way a form writes them:
  # "owner/name gate=ci.yml".
  defp repo_entry(%{repo: name} = entry) when is_binary(name),
    do: %{entry | repo: String.trim(name)}

  defp repo_entry(line) when is_binary(line) do
    case parse_repos(line) do
      {:ok, [entry]} -> entry
      _ -> %{repo: String.trim(line)}
    end
  end

  defp repo_entry(_), do: nil

  @doc """
  The repositories as a form shows and saves them, in settings order: a
  name, or a map of the name and the workflows that entry names for itself
  (`gate_workflow`, `dev_deploy`, `prod_deploy`).

  The first repository is always its name alone: its workflows are the
  gate, dev deploy and prod deploy fields. A workflow a form could not
  take back (a settings file can hold any text) is left out, and stays as
  the file has it.
  """
  def repo_fields(settings) do
    settings.github
    |> repo_entries()
    |> Enum.map(&repo_entry/1)
    |> Enum.filter(&(&1 && repo_name?(&1.repo)))
    |> Enum.uniq_by(& &1.repo)
    |> Enum.with_index()
    |> Enum.map(fn
      {entry, 0} ->
        entry.repo

      {entry, _} ->
        own =
          entry
          |> Map.take(@repo_keys)
          |> Map.filter(fn {_, file} ->
            is_nil(file) or (is_binary(file) and file =~ @workflow_file)
          end)

        if own == %{}, do: entry.repo, else: Map.put(own, :repo, entry.repo)
    end)
  end

  @doc ~S(One of `repo_fields/1` as a line of text: "owner/name gate=ci.yml".)
  def repo_line(name) when is_binary(name), do: name

  def repo_line(%{repo: name} = entry) do
    own =
      for {key, word} <- @repo_words, is_map_key(entry, key), do: "#{word}=#{entry[key]}"

    Enum.join([name | own], " ")
  end

  # Repositories as typed: names apart by commas, spaces or lines, each
  # with gate=, dev= and prod= after it for workflows of its own. Returns
  # {:ok, [%{repo: name, ...}]} or {:error, message}.
  defp parse_repos(text) do
    words = Map.new(@repo_words, fn {key, word} -> {word, key} end)

    text
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.reduce_while([], fn token, acc ->
      case {String.split(token, "=", parts: 2), acc} do
        {[name], _} ->
          if repo_name?(name),
            do: {:cont, [%{repo: name} | acc]},
            else: {:halt, {:error, "#{name} is not owner/name"}}

        {[word, file], [entry | rest]} when is_map_key(words, word) ->
          if file == "" or file =~ @workflow_file,
            do: {:cont, [Map.put(entry, words[word], blank_to_nil(file)) | rest]},
            else: {:halt, {:error, "#{file} is not a workflow file name, like ci.yml"}}

        _ ->
          {:halt,
           {:error,
            "#{token}: after a repository, write gate=, dev= or prod= and a workflow file"}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      entries -> {:ok, Enum.reverse(entries)}
    end
  end

  @doc """
  Entries the board leaves out because they are not owner/name, as written:
  from `repos`, or `repo` when `repos` is empty.
  """
  def skipped_repos(settings) do
    settings.github
    |> repo_entries()
    |> Enum.flat_map(fn raw ->
      case repo_entry(raw) do
        %{repo: name} -> if repo_name?(name), do: [], else: [name]
        nil -> [inspect(raw)]
      end
    end)
  end

  defp repo_entries(gh) do
    case List.wrap(gh[:repos]) do
      [] -> List.wrap(gh[:repo])
      list -> list
    end
  end

  @doc "The names (owner/name) of the repositories the board follows."
  def repo_names(settings), do: settings |> github_repos() |> Enum.map(& &1.repo)

  @doc "True for an owner/name repository name."
  def repo_name?(name), do: is_binary(name) and name =~ ~r{\A[\w.-]+/[\w.-]+\z}

  defp has_path?(map, [k]), do: is_map(map) and Map.has_key?(map, k)
  defp has_path?(map, [k | rest]), do: is_map(map) and has_path?(Map.get(map, k), rest)

  @doc "Replaces the cached settings. Used by tests."
  def put(settings), do: :persistent_term.put(@key, merge(@defaults, settings) |> normalize())

  def path, do: Enum.find(places(), &File.regular?/1)

  # Where the settings file is looked for, in order. A current folder that
  # has been removed under a running board is skipped, never an error:
  # the board looks here every two seconds.
  defp places do
    cwd =
      case File.cwd() do
        {:ok, dir} -> Path.join(dir, "settings.exs")
        _ -> nil
      end

    [
      System.get_env("WALLBOARD_SETTINGS"),
      System.get_env("RELEASE_ROOT") && Path.join(System.get_env("RELEASE_ROOT"), "settings.exs"),
      cwd
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(fn
      "/" <> _ = path -> path
      # A relative path needs the current folder to stand on.
      path -> if cwd, do: Path.expand(path), else: path
    end)
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
    role = role(settings)

    settings
    |> Map.put(:role, role)
    # A hub keeps only what other machines send.
    |> update_in([:archive, :collect_local], &(&1 && role != :hub))
    |> update_in([:claude, :poll_seconds], &whole(&1, @defaults.claude.poll_seconds))
    |> update_in([:codex, :idle_minutes], fn
      n when is_integer(n) and n >= 0 -> n
      _ -> @defaults.codex.idle_minutes
    end)
    |> update_in([:collector], fn c ->
      %{
        c
        | poll_seconds: whole(c[:poll_seconds], @defaults.collector.poll_seconds),
          backfill_days: whole(c[:backfill_days], @defaults.collector.backfill_days),
          outbox_mb: whole(c[:outbox_mb], @defaults.collector.outbox_mb),
          claude_dirs: c.claude_dirs && Enum.map(List.wrap(c.claude_dirs), &Path.expand/1),
          codex_dirs: c.codex_dirs && Enum.map(List.wrap(c.codex_dirs), &Path.expand/1),
          dir: collector_dir(c.dir)
      }
    end)
    |> update_in([:claude, :config_dirs], fn dirs -> Enum.map(List.wrap(dirs), &Path.expand/1) end)
    |> update_in([:codex, :dirs], fn dirs -> Enum.map(List.wrap(dirs), &Path.expand/1) end)
    |> update_in([:alerts], fn alerts ->
      Enum.reduce(
        [:phone, :slack_webhook, :ntfy_topic, :ntfy_server, :pushover_user, :pushover_token],
        alerts,
        fn key, acc -> Map.update(acc, key, nil, &blank_to_nil/1) end
      )
    end)
    |> update_in([:token], &blank_to_nil/1)
    # Only a note that a key is kept counts; a settings file never holds
    # the key itself.
    |> update_in([:new_relic, :api_key], fn
      %{} = note -> note
      _ -> nil
    end)
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

  @doc """
  Where a collector keeps its place and its unsent events: the setting when
  there is one, otherwise a "collector" folder beside the database's usual
  place (see `db_path/1`).
  """
  def collector_dir(dir) when is_binary(dir) and dir != "", do: Path.expand(dir)
  def collector_dir(_), do: nil |> db_path() |> Path.dirname() |> Path.join("collector")

  # A whole number of 1 or more, or the default: timers and date sums use
  # these, and a fraction or a nil there would stop the poller or the
  # collector on every round.
  defp whole(n, _default) when is_integer(n) and n >= 1, do: n
  defp whole(_, default), do: default

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
