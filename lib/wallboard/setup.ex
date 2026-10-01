defmodule Wallboard.Setup do
  @moduledoc """
  Changing this machine's settings, for the VitalAIze app and for the
  `vitalaize setup` terminal command. Both go through here, so both write
  the same file (settings.json, see `Wallboard.Settings`) and either can
  change what the other saved.

  ## What a save does

  `save/2` checks the values, writes the file and works out what the
  change touches (`plan/2`):

    * Most settings are read as they are used. The running board or
      collector looks at the file every two seconds
      (`Wallboard.Settings.Watch`), so those take effect by themselves.
    * A few are only read at the start: the ports, the role, the board
      password, whether the hub takes collectors. For those the service
      on this machine is restarted (`Wallboard.Setup.Service`), and only
      then. A hub that restarts tells its collectors "back soon" first,
      so they wait instead of trying again and again.

  One machine runs one service: the board (roles hub and both) or the
  collector. A setting for the part of the machine that is not running
  restarts nothing.

  ## The two ways in

    * `run/1`: questions and answers in a terminal. It reads plain lines,
      so a script can feed it.
    * `json/2`: what the VitalAIze app calls. `show` prints the settings
      and their fields, `save` takes values on standard input, `pair`
      pairs with a hub and prints the code as it goes.

  Both pair a collector with its hub by code (`Wallboard.Pairing.pair/1`)
  and say what pairing answered, whatever it was.

  ## A machine set up by 0.2.0

  Both also take out the upload hooks VitalAIze 0.2.0 added to this
  machine's Claude and Codex settings (`retire_old_hooks/2`), since the
  hub takes no uploads any more. `remove/1` is the other end: it takes out
  those hooks and this machine's certificate, for `vitalaize remove` and
  the app's Remove.
  """

  alias Wallboard.{Pairing, Settings}
  alias Wallboard.Setup.{OldHooks, Service}

  @marker "VITALAIZE_JSON"
  @code_marker "VITALAIZE_CODE"

  # ---------------------------------------------------------------------------
  # Saving

  @doc """
  Saves the given values (text, keyed by path, like `"alerts.phone"`) over
  the settings as they are; anything not given stays. Returns
  `{:ok, result}` or `{:error, %{path => message}}`, with nothing saved.
  Only the settings given are checked and changed (`Settings.change/2`).

  The result is `plan/2`'s map plus `path` (the file written), `role` and
  `service`: `:untouched` (nothing needed a restart), `:restarted`,
  `:stopped` (set up as a service but not running, so it starts with the
  new settings), `:by_hand` (not a service here) or `{:failed, why}`.
  """
  def save(values, opts \\ []) do
    before = Settings.load!()

    with :ok <- role_is_ours(values),
         {:ok, saved} <- Settings.change(values) do
      {:ok, saved!(before, saved, opts)}
    end
  end

  @doc """
  Takes the given settings (keys like `"port"`) out of the saved ones, so
  they follow the settings file again. The Mac app does this for what its
  wizard asks, just before it writes that file anew: an answer given
  there must not lose to an older saved value.

  Only settings.json is read and written. The settings file is not
  loaded, so one that does not load is no obstacle to replacing it, and
  nothing is restarted: a service stopped here would come back on the old
  settings file before the new one is written. The app starts the service
  again itself once the new file is there. Nothing is checked, so it
  cannot fail on a value. Returns `{:ok, %{path: path}}`, the file the
  saved settings are in.
  """
  def forget(keys) do
    :ok = Settings.forget!(keys)
    {:ok, %{path: Settings.saved_path()}}
  end

  defp saved!(before, saved, opts) do
    now = Settings.save!(saved)
    plan = plan(before, now)
    service = if plan.restart == [], do: :untouched, else: restart(opts)
    Map.merge(plan, %{path: Settings.saved_path(), role: now.role, service: service})
  end

  # WALLBOARD_ROLE wins over anything saved. Saving another role under it
  # would change nothing here and then surprise a start without it.
  defp role_is_ours(values) do
    case {System.get_env("WALLBOARD_ROLE"), values["role"]} do
      {env, role} when is_binary(env) and env != "" and is_binary(role) ->
        if String.trim(env) == String.trim(role),
          do: :ok,
          else:
            {:error,
             %{
               "role" =>
                 "What this machine does: WALLBOARD_ROLE is set to #{String.trim(env)} here and " <>
                   "wins over this. Take it out of the environment to change the role."
             }}

      _ ->
        :ok
    end
  end

  defp restart(opts) do
    case Service.state(opts) do
      :running ->
        case Service.restart(opts) do
          :ok -> :restarted
          {:error, why} -> {:failed, why}
        end

      :stopped ->
        :stopped

      :none ->
        :by_hand
    end
  end

  @doc """
  What changed between two loaded settings, and what it takes:

    * `changed`: every changed field, as `%{path, label, part, restart?}`
    * `live`: those that take effect by themselves
    * `restart`: those that need the service restarted
    * `parts`: which parts of the machine the restart is for (`:hub`,
      `:collector`, `:machine` for a change of role)

  A change to a part this machine does not run (the board's settings on
  a collector, a collector's on a board) is live: nothing runs it.
  """
  def plan(before, now) do
    changed =
      for {_section, fields} <- Settings.editable(),
          {path, label, type, restart?, _help} <- fields,
          Settings.current(before, path, type) != Settings.current(now, path, type) do
        part = Settings.part(path)
        %{path: path, label: label, part: part, restart?: restart? and runs?(now.role, path)}
      end

    restart = Enum.filter(changed, & &1.restart?)

    %{
      changed: changed,
      live: changed -- restart,
      restart: restart,
      parts: restart |> Enum.map(& &1.part) |> Enum.uniq()
    }
  end

  # Whether a machine in this role runs the thing a setting is for.
  defp runs?(_role, [:role]), do: true
  defp runs?(:collector, [:collector | _]), do: true
  defp runs?(:collector, _path), do: false
  defp runs?(_board, [:collector | _]), do: false
  defp runs?(_board, _path), do: true

  @doc "What a save did, as sentences for the person who saved."
  def report(%{changed: []}), do: ["Nothing changed."]

  def report(result) do
    name = if result.role == :collector, do: "the collector", else: "the board"
    labels = fn fields -> Enum.map_join(fields, ", ", & &1.label) end

    ["Saved in #{result.path}."] ++
      if(result.live == [],
        do: [],
        else: ["In use within a few seconds, with no restart: #{labels.(result.live)}."]
      ) ++
      case {result.restart, result.service} do
        {[], _} ->
          []

        {fields, :restarted} ->
          [
            "Restarted #{name} to take up: #{labels.(fields)}." <>
              if(result.role == :collector,
                do: "",
                else: " A hub tells its collectors it will be back soon before it stops."
              )
          ]

        {fields, :stopped} ->
          ["These take effect when #{name} next starts: #{labels.(fields)}."]

        {fields, :by_hand} ->
          [
            "These need a restart: #{labels.(fields)}. " <>
              String.capitalize(name) <>
              " does not run as a service here, so stop it and start it again."
          ]

        {fields, {:failed, why}} ->
          [
            "Could not restart #{name} (#{why}). Restart it by hand to take up: " <>
              "#{labels.(fields)}."
          ]
      end
  end

  # ---------------------------------------------------------------------------
  # Hooks from before the streaming collector, and removing VitalAIze

  @doc """
  Takes the upload hooks VitalAIze 0.2.0 added out of this machine's
  Claude and Codex settings, and deletes its upload script (see
  `Wallboard.Setup.OldHooks`). Every other hook stays as it was, and each
  file changed is copied first. Returns what it did as sentences, none
  when there was nothing of the kind.

  Options, for tests: `home`, `env` and `data` (`OldHooks.folders/2`).
  """
  def retire_old_hooks(settings, opts \\ []) do
    settings
    |> OldHooks.folders(Keyword.take(opts, [:home, :env, :data]))
    |> OldHooks.retire()
    |> OldHooks.report()
  end

  @doc """
  Takes VitalAIze's traces off this machine, short of its program and its
  settings: the old upload hooks, and the certificate and hub address
  pairing saved. Returns what it did as sentences. The service is the
  caller's to stop first (the VitalAIze app does, and `vitalaize remove`).
  """
  def remove(opts \\ []) do
    settings = settings_or_defaults()
    retire_old_hooks(settings, opts) ++ forget_hub(settings)
  end

  # A settings file that does not load must not keep VitalAIze on the
  # machine: the usual folders are still looked in.
  defp settings_or_defaults do
    Settings.load!()
  rescue
    _ -> Settings.normalize(Settings.defaults())
  end

  defp forget_hub(settings) do
    dir = Pairing.dir(settings)

    if File.dir?(dir) and OldHooks.allowed?(dir) do
      File.rm_rf(dir)

      [
        "Deleted this machine's certificate and its hub's address (#{dir}). " <>
          "On the hub's board, open Settings and Disconnect this machine."
      ]
    else
      []
    end
  end

  @doc """
  `vitalaize remove`, in a terminal: asks first, then stops the service
  and takes it out of what starts at login (Linux; a Mac's login item is
  the app's), then `remove/1`. Settings and saved sessions stay.

  Options: `io`, and for tests `remove/1`'s and
  `Wallboard.Setup.Service`'s.
  """
  def remove_here(opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)

    say(io, """
    This stops VitalAIze on this machine and takes it out of what starts at
    login. It also takes out the upload hooks an earlier version added to
    Claude and Codex, and this machine's certificate for its hub. Your
    settings and saved sessions stay where they are.
    """)

    if yes?(gets(io, "Remove VitalAIze from this machine? (yes or no) [no]: ")) do
      case {Service.kind(opts), Service.state(opts)} do
        {_, :none} ->
          :ok

        {:systemd, _} ->
          case Service.uninstall(opts) do
            :ok -> say(io, "Stopped VitalAIze. It no longer starts when you log in.")
            {:error, why} -> say(io, "Could not stop the service: #{why}")
          end

        _ ->
          say(io, "VitalAIze still runs as a login item. Open the VitalAIze app to remove that.")
      end

      Enum.each(remove(opts), &say(io, &1))

      say(io, """
      Done. Your settings are still in #{Path.dirname(Settings.saved_path())}.
      Delete that folder, and the folder VitalAIze was unpacked in, to remove the rest.
      """)
    else
      say(io, "Nothing removed.")
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # The terminal command

  @doc """
  The start of `vitalaize setup` and `vitalaize remove`. With no arguments
  it asks setup's questions; `remove` takes VitalAIze off this machine;
  `--json show`, `--json save`, `--json pair [address]`, `--json hubs`,
  `--json retire` and `--json remove` are for the VitalAIze app. Stops
  with status 1 when it could not do what was asked.
  """
  def main(args \\ argv()) do
    # Run by itself, beside the board or with none running: only what
    # pairing and the settings need is started, and no log lines land
    # among the questions.
    :logger.set_primary_config(:level, :error)

    for app <- [:crypto, :public_key, :ssl, :inets, :jason],
        do: Application.ensure_all_started(app)

    result =
      try do
        case args do
          ["--json" | rest] -> json(rest)
          [] -> run()
          ["remove"] -> remove_here()
          _ -> {:error, "Usage: vitalaize setup, or vitalaize remove"}
        end
      rescue
        # Our own messages say what to do. Anything else may quote a line
        # of the settings file, which can hold a password.
        e in ArgumentError -> {:error, Exception.message(e)}
        e -> {:error, "VitalAIze setup stopped: #{inspect(e.__struct__)}"}
      end

    case result do
      {:error, message} when is_binary(message) ->
        # The app waits for an answer line, so it gets one.
        if match?(["--json" | _], args),
          do: emit([], %{ok: false, message: message, lines: [message]}),
          else: IO.puts(:stderr, message)

        System.halt(1)

      {:error, _} ->
        System.halt(1)

      _ ->
        :ok
    end
  end

  defp argv do
    case System.get_env("VITALAIZE_ARGS") do
      text when is_binary(text) -> String.split(text)
      _ -> []
    end
  end

  @doc """
  Asks what this machine should do and the settings that go with it, in a
  terminal, then saves, takes out the old upload hooks, pairs a collector
  with its hub, and offers to keep VitalAIze running. Enter keeps a value;
  `-` empties it.

  Options: `io` (the device to read and write, standard input and output
  unless given), and for tests `pair`, `discover`, `poll_ms`,
  `retire_old_hooks/2`'s, and `Wallboard.Setup.Service`'s `run` and `os`.
  """
  def run(opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)
    settings = Settings.load!()
    shown = Settings.shown(settings)

    say(io, """
    VitalAIze setup. Enter keeps what is in [brackets]; - empties it.
    Settings are saved in #{Settings.saved_path()}.
    """)

    [{_, [role_field]} | _] = Settings.editable()
    values = ask(io, role_field, shown, %{})
    role = values |> Map.get("role", shown["role"]) |> String.to_existing_atom()

    values =
      case Settings.editable(role) do
        [_machine, {_collector, fields}] when role == :collector ->
          Enum.reduce(fields, values, &ask(io, &1, shown, &2))

        [_machine | sections] ->
          menu(io, sections, shown, values)
      end

    with %{} <- values,
         {:ok, result} <- save(values, opts) do
      Enum.each(report(result), &say(io, &1))
      # Before pairing, so the new collector never runs beside the old hooks.
      Enum.each(retire_old_hooks(Settings.get(), opts), &say(io, &1))
      if result.role == :collector, do: pairing(io, opts)
      keep_running(io, result, opts)
      :ok
    else
      :quit ->
        say(io, "Nothing saved.")
        :ok

      {:error, errors} ->
        for {_path, message} <- Enum.sort(errors), do: say(io, message)
        say(io, "Nothing saved.")
        {:error, errors}
    end
  end

  defp menu(io, sections, shown, values) do
    say(io, "\nWhat to change:")

    for {{title, _}, n} <- Enum.with_index(sections, 1),
        do: say(io, "  #{String.pad_leading("#{n}", 2)}. #{title}")

    case gets(io, "A number, Enter to save and finish, or q to leave without saving: ") do
      nil ->
        values

      "" ->
        values

      "q" ->
        :quit

      text ->
        case Integer.parse(text) do
          {n, ""} when n >= 1 and n <= length(sections) ->
            {title, fields} = Enum.at(sections, n - 1)
            say(io, "\n#{title}")
            menu(io, sections, shown, Enum.reduce(fields, values, &ask(io, &1, shown, &2)))

          _ ->
            say(io, "Type one of the numbers above.")
            menu(io, sections, shown, values)
        end
    end
  end

  # One question. The answer, when there is one, goes into `values`.
  defp ask(io, {path, label, type, _restart, help} = field, shown, values) do
    key = Enum.join(path, ".")
    current = Map.get(values, key, shown[key])
    # In a terminal a list is typed on one line, with commas.
    if help, do: say(io, "  (#{String.replace(help, "One per line. ", "")})")

    case gets(io, "#{label}#{hint(type)} [#{display(type, current)}]: ") do
      nil ->
        values

      "" ->
        values

      text ->
        answer = answer(type, text)

        case Settings.check_one(field, answer) do
          :ok ->
            Map.put(values, key, answer)

          {:error, message} ->
            say(io, "  #{label}: #{message}")
            ask(io, {path, label, type, false, nil}, shown, values)
        end
    end
  end

  defp hint({:choice, options}), do: " (#{Enum.join(options, ", ")})"
  defp hint(:boolean), do: " (yes or no)"
  defp hint(type) when type in [:lines, :repos, :folders], do: " (commas between them)"
  defp hint(_), do: ""

  defp display(:folders, ""), do: "found by itself"
  defp display(_type, ""), do: "none"
  defp display(:secret, _), do: "set"
  defp display(:boolean, "true"), do: "yes"
  defp display(:boolean, _), do: "no"

  defp display(type, text) when type in [:lines, :repos, :folders],
    do: text |> String.split("\n") |> Enum.join(", ")

  defp display(_type, text), do: text

  defp answer(_type, "-"), do: ""

  defp answer(:boolean, text),
    do: to_string(String.downcase(text) in ["y", "yes", "true", "on"])

  defp answer(type, text) when type in [:lines, :repos, :folders],
    do: text |> String.split(",") |> Enum.map_join("\n", &String.trim/1)

  defp answer(_type, text), do: text

  # Pairing a collector with its hub: the code is shown here, and the
  # owner approves the same code in the hub's mailbox.
  defp pairing(io, opts) do
    dir = Pairing.dir(Settings.get())

    # nil keeps things as they are; "" looks for a hub on the network.
    address =
      case Pairing.load(dir) do
        {:ok, %{host: host, machine: machine}} ->
          say(io, "\nThis machine is paired with the hub at #{host} as #{machine}.")

          case gets(io, "A hub's address to pair again, or Enter to keep this: ") do
            "" -> nil
            other -> other
          end

        :error ->
          say(io, "\nThis machine is not paired with a hub yet.")

          case gets(io, "The hub's address (Enter looks for one on this network, - skips): ") do
            nil ->
              nil

            "-" ->
              say(io, "Not paired. Run vitalaize setup again to pair.")
              nil

            other ->
              other
          end
      end

    case address do
      nil ->
        :ok

      address ->
        with {:ok, address} <- hub_address(io, address, opts) do
          pair = Keyword.get(opts, :pair, &Pairing.pair/1)

          pair.(
            hub: address,
            dir: dir,
            poll_ms: opts[:poll_ms],
            on_code: fn %{code: code, hub: name, expires_in: secs} ->
              say(io, """

                  #{code}

              Open the mailbox on #{if name == "", do: "the hub", else: name}'s board and approve this code.
              It matches only this machine and expires in #{div(secs, 60)} minutes.
              Waiting for the hub to approve...
              """)
            end
          )
        end
        |> case do
          {:ok, %{machine: machine}} ->
            say(io, "Approved. This machine is connected as #{machine}.")

          {:error, message} when is_binary(message) ->
            say(io, message)

          {:error, reason} ->
            say(io, Pairing.why(reason))
        end
    end
  end

  defp hub_address(_io, address, _opts) when address != "", do: {:ok, address}

  defp hub_address(io, "", opts) do
    say(io, "Looking for a hub on this network...")
    discover = Keyword.get(opts, :discover, &Pairing.discover/0)

    case discover.() do
      [%{host: host, port: port, name: name}] ->
        say(io, "Found #{name}.")
        {:ok, "#{host}:#{port}"}

      [] ->
        {:error, "No hub found on this network. Run vitalaize setup again with its address."}

      hubs ->
        {:error,
         "More than one hub answered. Run vitalaize setup again with the address of one:\n" <>
           Enum.map_join(hubs, "\n", &"  #{&1.host}:#{&1.port}   (#{&1.name})")}
    end
  end

  # After a save: when nothing keeps VitalAIze running here, offer to.
  defp keep_running(io, result, opts) do
    name = if result.role == :collector, do: "the collector", else: "the board"

    case {Service.state(opts), Service.kind(opts)} do
      {:none, :systemd} ->
        say(io, "\nNothing starts #{name} when you log in yet.")

        if yes?(
             gets(io, "Set it up as a systemd user service and start it now? (yes or no) [no]: ")
           ) do
          case Service.install(opts) do
            :ok -> say(io, "#{String.capitalize(name)} is on, and starts whenever you log in.")
            {:error, why} -> say(io, "Could not set the service up: #{why}")
          end
        else
          say(io, "Start it yourself with bin/wallboard start.")
        end

      {:none, :launchd} ->
        say(
          io,
          "\nTo start #{name} when you log in, open the VitalAIze app. " <>
            "To run it now, bin/wallboard start."
        )

      {:none, :none} ->
        say(io, "\nStart #{name} with bin/wallboard start.")

      _ ->
        :ok
    end
  end

  defp yes?(text), do: is_binary(text) and String.downcase(text) in ["y", "yes"]

  defp say(io, text), do: IO.puts(io, text)

  # One line of input without its end, or nil when there is no more.
  defp gets(io, prompt) do
    case IO.gets(io, prompt) do
      text when is_binary(text) -> String.trim(text)
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # For the VitalAIze app

  @doc """
  What the VitalAIze app calls. Each answer is one line that starts with
  `VITALAIZE_JSON`, so anything else printed around it is easy to skip.

    * `["show"]`: the role, where the settings are saved, the sections and
      fields for this role with their values (a secret that is set comes
      as `kept`), whether this machine is paired, and the service's state.
    * `["save"]`: reads `{"values": {"alerts.phone": "..."}}` from standard
      input, saves, and answers `ok`, `lines` (what happened, to show) and
      `service`, or `ok: false` and `errors` by path.
    * `["forget"]`: reads `{"keys": ["port", ...]}` from standard input and
      takes those settings out of the saved ones (`forget/1`). It loads no
      settings and restarts nothing.
    * `["pair"]` or `["pair", address]`: pairs with a hub. The code comes
      first, on a line that starts with `VITALAIZE_CODE`; the answer
      follows when the owner has decided.
    * `["hubs"]`: the hubs found on the local network.
    * `["retire"]`: takes out the old upload hooks (`retire_old_hooks/2`)
      and answers `lines`, what it did.
    * `["remove"]`: `remove/1`, and answers `lines`. It works beside a
      settings file that does not load.
  """
  def json(args, opts \\ [])

  def json(["show"], opts) do
    settings = Settings.load!()
    shown = Settings.shown(settings)

    emit(opts, %{
      role: settings.role,
      path: Settings.saved_path(),
      kept: Settings.kept(),
      service: Service.state(opts),
      paired: paired(settings),
      sections:
        for {title, fields} <- Settings.editable(settings.role) do
          %{
            title: title,
            fields:
              for {path, label, type, restart?, help} <- fields do
                {kind, options} =
                  case type do
                    {:choice, options} -> {"choice", options}
                    other -> {Atom.to_string(other), []}
                  end

                key = Enum.join(path, ".")

                %{
                  key: key,
                  label: label,
                  type: kind,
                  options: options,
                  restart: restart?,
                  help: help,
                  part: Settings.part(path),
                  value: shown[key]
                }
              end
          }
        end
    })
  end

  def json(["save"], opts) do
    input = opts |> Keyword.get(:io, :stdio) |> IO.read(:eof)

    with text when is_binary(text) <- input,
         {:ok, %{"values" => %{} = values}} <- Jason.decode(text),
         true <- Enum.all?(values, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      case save(values, opts) do
        {:ok, result} ->
          emit(opts, %{
            ok: true,
            lines: report(result),
            role: result.role,
            service: service_name(result.service)
          })

        {:error, errors} ->
          emit(opts, %{ok: false, errors: errors})
          {:error, errors}
      end
    else
      _ -> {:error, ~s(Give {"values": {...}} with text values on standard input.)}
    end
  end

  def json(["forget"], opts) do
    input = opts |> Keyword.get(:io, :stdio) |> IO.read(:eof)

    with text when is_binary(text) <- input,
         {:ok, %{"keys" => keys}} when is_list(keys) <- Jason.decode(text),
         true <- Enum.all?(keys, &is_binary/1) do
      {:ok, result} = forget(keys)
      emit(opts, %{ok: true, path: result.path})
    else
      _ -> {:error, ~s(Give {"keys": ["port", ...]} on standard input.)}
    end
  end

  def json(["pair" | rest], opts) do
    out = Keyword.get(opts, :out, :stdio)
    settings = Settings.load!()
    address = List.first(rest) || ""
    silent = Keyword.put(opts, :discover, Keyword.get(opts, :discover, &Pairing.discover/0))

    result =
      with {:ok, address} <- quiet_address(address, silent) do
        pair = Keyword.get(opts, :pair, &Pairing.pair/1)

        pair.(
          hub: address,
          dir: Pairing.dir(settings),
          poll_ms: opts[:poll_ms],
          on_code: &IO.puts(out, @code_marker <> Jason.encode!(&1))
        )
      end

    case result do
      {:ok, %{machine: machine}} ->
        emit(opts, %{ok: true, machine: machine, message: "This Mac is connected as #{machine}."})

      {:error, message} when is_binary(message) ->
        emit(opts, %{ok: false, message: message})
        {:error, :not_paired}

      {:error, reason} ->
        emit(opts, %{ok: false, message: Pairing.why(reason)})
        {:error, :not_paired}
    end
  end

  def json(["hubs"], opts) do
    discover = Keyword.get(opts, :discover, &Pairing.discover/0)
    emit(opts, %{hubs: discover.()})
  end

  def json(["retire"], opts),
    do: emit(opts, %{ok: true, lines: retire_old_hooks(settings_or_defaults(), opts)})

  def json(["remove"], opts), do: emit(opts, %{ok: true, lines: remove(opts)})

  def json(_other, _opts),
    do: {:error, "Usage: --json show | save | forget | pair [address] | hubs | retire | remove"}

  defp quiet_address("", opts) do
    case opts[:discover].() do
      [%{host: host, port: port}] -> {:ok, "#{host}:#{port}"}
      [] -> {:error, "No hub found on this network. Type the hub's address."}
      _ -> {:error, "More than one hub answered. Type the address of the one you want."}
    end
  end

  defp quiet_address(address, _opts), do: {:ok, address}

  defp paired(settings) do
    case Pairing.load(Pairing.dir(settings)) do
      {:ok, %{host: host, port: port, machine: machine}} ->
        %{host: host, port: port, machine: machine}

      :error ->
        nil
    end
  end

  defp service_name({:failed, why}), do: "failed: #{why}"
  defp service_name(other), do: Atom.to_string(other)

  defp emit(opts, map) do
    IO.puts(Keyword.get(opts, :out, :stdio), @marker <> Jason.encode!(map))
    :ok
  end
end
