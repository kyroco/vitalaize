defmodule Wallboard.Collector.Sender do
  @moduledoc """
  Sends the collector's outbox to the hub over the link, in order, and
  drops from the outbox what has been handed on.

  It joins three parts that know nothing of each other: the watcher
  (`Wallboard.Collector.Watcher`), which reads the session files; the outbox
  (`Wallboard.Collector.Outbox`), which keeps the watcher's events on disk;
  and the link's client (`Wallboard.Link.Client`), which holds each event
  in its own buffer on disk until the hub says it is saved.

  ## Where the hub is

  Its folder (`Wallboard.Pairing.dir/1`, the collector's folder's `link`)
  holds what pairing leaves there: `cert.pem`, `key.pem` and `ca.pem`, and
  `hub.json` with the
  hub's address, such as `{"host": "192.168.1.20", "port": 4747, "link_port": 4748}`.
  `port` is the board's own, where the client asks the pairing door
  whether this machine was removed while it was away; a machine paired
  before VitalAIze saved it asks on 4747, the board's usual port.
  Until all four are there nothing is sent, and the outbox keeps the
  events. The sender looks for them twice a second, so a collector paired
  for the first time while it runs starts sending without a restart. A
  collector paired again while it runs (after the hub removed it, or with
  another hub) is seen the same way: when `cert.pem` or `hub.json` change,
  the sender stops its client and starts one with what is there now.

  ## Sending

  It takes a couple of hundred events from the outbox, hands them to the
  client, and only then tells the outbox they can go: the client has them
  on disk by then. It stops handing over while the client's buffer holds
  more than #{div(4_000_000, 1_000_000)} MB, so that buffer never fills
  and the outbox, which is the larger, does the waiting.

  ## The hub's place is the truth

  On every connect the hub says how far it has each session file. The
  sender then has the watcher go back to those places
  (`Wallboard.Collector.Watcher.rewind/2`). A file the hub has less of than
  the collector has read is read again from the hub's place, and what was
  already waiting of that file, in the outbox and in the client's buffer,
  is dropped unsent: the lines read again replace it. The client sends
  nothing between the hub's word and the moment that is done (`hold`). So
  after a dropout, a restart of either side, or a hub that lost some of
  what it had, the hub gets each file's lines in order with none missing,
  whatever was on its way before.

  Which events are dropped unsent is kept in `skip.json` in the collector's
  folder, so a collector that stops halfway through does not send them
  after it starts again.

  ## GitHub runners

  Every few seconds it also looks for GitHub Actions runners on this
  machine (`Wallboard.Collector.Runners`) and hands the client their names
  and states, through `Wallboard.Collector.Filter.runners/1`. The client
  sends them when they change; they skip the outbox and nothing of them is
  kept on disk. A runner whose `.runner` file this user cannot read has no
  name here and is not sent; that is logged once for each such folder.

  ## How the link stands

  Every time the stream to the hub opens or is lost, the sender writes
  that in `state.json` beside the certificate, for the VitalAIze app and
  `vitalaize setup` to show (`link_state/1`): the app runs as its own
  program and cannot ask the collector.
  """

  use GenServer
  require Logger

  alias Wallboard.Collector.{Filter, Outbox, Proto, Runners, Watcher}
  alias Wallboard.Link.{Authority, Client}

  @tick_ms 500
  # How often the process list is read for GitHub runners.
  @runners_ms 5_000
  @batch 200
  @high_water 4_000_000
  # How long "the hub is restarting" stands before a lost stream is said
  # as lost.
  @back_soon_seconds 120
  # The board's usual port, for a collector paired before `hub.json` held
  # the board's own.
  @board_port 4747

  def start_link(opts) do
    # `name: nil` starts one without a name, for tests.
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  What pairing left in the collector's folder `dir`:
  `{:ok, %{tls: %{cert_pem, key_pem, ca_pem}, host, port, door}}`, where
  `port` is the link's and `door` is the board's address `%{host, port}`,
  or `:error` while any of it is missing or cannot be read.
  """
  def paired(dir) do
    with {:ok, cert} <- File.read(Path.join(dir, "cert.pem")),
         {:ok, key} <- File.read(Path.join(dir, "key.pem")),
         {:ok, ca} <- File.read(Path.join(dir, "ca.pem")),
         {:ok, text} <- File.read(Path.join(dir, "hub.json")),
         {:ok, %{"host" => host, "link_port" => port} = hub}
         when is_binary(host) and host != "" and is_integer(port) and port > 0 and port < 65_536 <-
           Jason.decode(text) do
      board =
        case hub["port"] do
          board when is_integer(board) and board > 0 and board < 65_536 -> board
          _ -> @board_port
        end

      {:ok,
       %{
         tls: %{cert_pem: cert, key_pem: key, ca_pem: ca},
         host: host,
         port: port,
         door: %{host: host, port: board}
       }}
    else
      _ -> :error
    end
  end

  @states ["up", "down", "back_soon", "removed"]

  @doc """
  How the link stands, as the running collector last wrote it in `dir`:
  `{:ok, %{state: state, at: unix_seconds}}`, where `state` is `"up"` (the
  stream to the hub is open), `"down"` (no connection now; it keeps
  trying), `"back_soon"` (the hub said it is restarting) or `"removed"`
  (the hub revoked this machine). `:error` when nothing was written: the
  machine is not paired, or no collector has run since it was.
  """
  def link_state(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "state.json")),
         {:ok, %{"state" => state, "at" => at}} when state in @states and is_integer(at) <-
           Jason.decode(text) do
      {:ok, %{state: state, at: at}}
    else
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      dir: Keyword.fetch!(opts, :dir),
      outbox: Keyword.get(opts, :outbox, Outbox),
      watcher: Keyword.get(opts, :watcher, Watcher),
      # Passed on to the client: its name, pace and waits, for tests.
      client_opts: Keyword.get(opts, :client, []),
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      # The process list, for the GitHub runners on this machine (see
      # `Wallboard.Collector.Runners.read/1`). Tests give their own.
      processes: Keyword.get(opts, :processes, &Runners.processes/0),
      runners_ms: Keyword.get(opts, :runners_ms, @runners_ms),
      # The runners as last read, as the message for the hub, and what has
      # been logged once already.
      runners: nil,
      logged: MapSet.new(),
      # The look at the runners under way, if one is.
      runners_task: nil,
      client: nil,
      # The hub's positions still to go back to, then the files the
      # client is still to forget, and whether both have been done at
      # least once: nothing is sent before.
      resume: nil,
      forget: nil,
      ready?: false,
      # file => the outbox number up to which its events are not sent
      skip: %{},
      removed?: false,
      warned?: false,
      # cert.pem and hub.json as they were when the client was started
      paired_as: nil,
      # the last word written to state.json, and when
      noted: nil
    }

    state = %{state | skip: saved_skip(state.dir)}

    send(self(), :tick)
    send(self(), :runners)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state |> connect() |> rewind() |> pump()}
  end

  # The runners are read in a task of their own, so a slow read (`ps`, or a
  # .runner some program made hard to read) never holds up the sessions'
  # events. A look starts only when the last one has answered, and the task
  # is never stopped early: it ends by itself, and a `head` it started is
  # killed when its time is up (see `Wallboard.Collector.Runners`).
  def handle_info(:runners, %{runners_task: nil} = state) do
    Process.send_after(self(), :runners, state.runners_ms)
    processes = state.processes

    task =
      Task.Supervisor.async_nolink(Wallboard.TaskSupervisor, fn -> Runners.read(processes) end)

    {:noreply, %{state | runners_task: task}}
  end

  def handle_info(:runners, state) do
    Process.send_after(self(), :runners, state.runners_ms)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{runners_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | runners_task: nil}
    {:noreply, state |> read_runners(result) |> give_runners()}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{runners_task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | runners_task: nil}}

  def handle_info({:wallboard_link, {:resume, points}}, state),
    do: {:noreply, %{state | resume: points} |> rewind() |> pump()}

  def handle_info({:wallboard_link, {:stored, _seq}}, state), do: {:noreply, pump(state)}

  def handle_info({:wallboard_link, :removed}, state) do
    Logger.warning("Collector: the hub removed this machine. Nothing more is sent.")
    {:noreply, %{note(state, "removed") | removed?: true}}
  end

  def handle_info({:wallboard_link, :up}, state), do: {:noreply, note(state, "up")}

  # A hub that said it is restarting closes the stream a moment later.
  # That is the restart, not a hub that went quiet, for as long as a
  # restart takes.
  def handle_info({:wallboard_link, {:down, _wait}}, %{noted: {"back_soon", at}} = state) do
    if System.os_time(:second) - at < @back_soon_seconds,
      do: {:noreply, state},
      else: {:noreply, note(state, "down")}
  end

  def handle_info({:wallboard_link, {:down, _wait}}, state),
    do: {:noreply, note(state, "down")}

  def handle_info({:wallboard_link, :back_soon}, state),
    do: {:noreply, note(state, "back_soon")}

  def handle_info(_other, state), do: {:noreply, state}

  # Never print events or certificates in a crash report.
  @impl true
  def format_status(status) do
    status
    |> Map.update(:state, nil, &Map.take(&1, [:dir, :ready?, :removed?, :runners]))
    |> Map.replace(:message, :not_shown)
    |> Map.replace(:log, [])
  end

  # ---------------------------------------------------------------------------

  # Starts the link's client once the collector is paired. The two live and
  # stop together.
  defp connect(%{client: nil} = state) do
    # Taken before the files are read, so a pairing that lands meanwhile
    # is seen as a change on the next look.
    paired_as = stamp(state.dir)

    with {:ok, hub} <- paired(state.dir),
         %Proto.Hello{} = hello <- hello(state) do
      if certificate?(hub.tls) do
        opts =
          Keyword.merge(
            [
              host: hub.host,
              port: hub.port,
              tls: hub.tls,
              hello: hello,
              buffer: Path.join(state.dir, "link.buffer"),
              door: hub.door,
              listener: self(),
              # Nothing leaves the client's buffer until the watcher has
              # gone back to the hub's place.
              hold: true
            ],
            state.client_opts
          )

        {:ok, pid} = Client.start_link(opts)
        Logger.info("Collector: sending to the hub at #{inspect(hub.host)}, port #{hub.port}.")
        # Not connected until the client says so.
        give_runners(%{note(state, "down") | client: pid, paired_as: paired_as})
      else
        if not state.warned?,
          do: Logger.warning("Collector: the certificate files could not be read. Pair again.")

        %{state | warned?: true}
      end
    else
      _ -> state
    end
  end

  # Paired again while running: the certificate in use is no longer the
  # one in the folder, and the hub may be another one.
  defp connect(%{client: pid} = state) do
    if stamp(state.dir) == state.paired_as do
      state
    else
      Logger.info("Collector: paired again. Connecting with the new certificate.")

      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      # What the old client said last is about the old pairing.
      drain()

      connect(%{
        state
        | client: nil,
          removed?: false,
          ready?: false,
          resume: nil,
          forget: nil,
          warned?: false
      })
    end
  end

  defp drain do
    receive do
      {:wallboard_link, _} -> drain()
    after
      0 -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # GitHub runners

  # What a look at the runners found, `Runners.read/1`'s answer.
  defp read_runners(state, result) do
    case result do
      {list, unnamed} ->
        message = Filter.runners(list)
        sent = MapSet.new(message.runners, & &1.name)

        state =
          Enum.reduce(unnamed, state, fn folder, state ->
            once(state, {:unnamed, folder}, fn ->
              "Collector: a GitHub runner runs from #{folder}, but this user cannot " <>
                "read its .runner file, so its name and state are not sent."
            end)
          end)

        state =
          list
          |> Enum.reject(&MapSet.member?(sent, &1.name))
          |> Enum.reduce(state, fn %{name: name}, state ->
            once(state, {:shape, name}, fn ->
              "Collector: the GitHub runner #{inspect(name)} is not sent: a runner name " <>
                "is letters, digits, dots, underscores and hyphens, up to 64."
            end)
          end)

        %{state | runners: message}

      :error ->
        once(state, :ps, fn ->
          "Collector: the process list could not be read, so no GitHub runner is sent."
        end)
    end
  end

  defp once(state, key, line) do
    if MapSet.member?(state.logged, key) do
      state
    else
      Logger.warning(line.())
      %{state | logged: MapSet.put(state.logged, key)}
    end
  end

  # The client sends them only when they changed, and again after each
  # connect.
  defp give_runners(%{client: pid, runners: %Proto.RunnerStates{} = runners} = state)
       when is_pid(pid) do
    Client.runners(pid, runners)
    state
  end

  defp give_runners(state), do: state

  # When cert.pem and hub.json were last written, and how long they are.
  defp stamp(dir) do
    for name <- ["cert.pem", "hub.json"] do
      case File.stat(Path.join(dir, name), time: :posix) do
        {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
        _ -> nil
      end
    end
  end

  # Writes how the link stands (see `link_state/1`). The file is written
  # whole beside itself and moved into place, so a reader never sees half
  # of it; a folder that cannot be written costs only the note.
  defp note(state, word) do
    path = Path.join(state.dir, "state.json")
    tmp = path <> ".tmp"

    at = System.os_time(:second)

    with :ok <- File.write(tmp, Jason.encode!(%{state: word, at: at})) do
      File.rename(tmp, path)
    end

    %{state | noted: {word, at}}
  end

  # Read before the client is started: files that are there and are not a
  # certificate must not stop the collector.
  defp certificate?(tls) do
    Authority.collector_tls(tls)
    true
  rescue
    _ -> false
  end

  defp hello(state) do
    Watcher.hello(state.watcher)
  catch
    :exit, _ -> nil
  end

  # Goes back to the hub's place in each file. Until that has worked, no
  # event is handed on.
  # In two steps, each tried again on its own until it has worked: the
  # watcher goes back (and what not to send is written down), then the
  # client forgets what it held of those files and may send again.
  defp rewind(state), do: state |> go_back() |> forget()

  defp go_back(%{resume: nil} = state), do: state

  defp go_back(state) do
    case watcher_rewind(state) do
      {:ok, files, seq} ->
        skip = Enum.reduce(files, state.skip, &Map.put(&2, &1, seq))
        state = save_skip(state, skip)
        %{state | resume: nil, forget: Enum.uniq(files ++ (state.forget || []))}

      :retry ->
        state
    end
  end

  defp watcher_rewind(state) do
    Watcher.rewind(state.watcher, state.resume)
  catch
    :exit, _ -> :retry
  end

  defp forget(%{forget: nil} = state), do: state
  # A newer word from the hub came meanwhile: go back to that one first.
  defp forget(%{resume: points} = state) when points != nil, do: state

  defp forget(state) do
    :ok = Client.rewound(state.client, state.forget)
    %{state | forget: nil, ready?: true}
  catch
    :exit, _ -> state
  end

  defp pump(%{client: nil} = state), do: state
  defp pump(%{ready?: false} = state), do: state
  defp pump(%{removed?: true} = state), do: state
  defp pump(%{resume: points} = state) when points != nil, do: state
  defp pump(%{forget: files} = state) when files != nil, do: state

  defp pump(state) do
    case Outbox.stats(state.outbox) do
      # A number past the outbox's last is from an outbox that is gone (its
      # folder was cleared): it says nothing about this one.
      %{acked: acked, seq: seq} ->
        state
        |> save_skip(Map.reject(state.skip, fn {_, floor} -> floor > seq end))
        |> pump(acked)

      _ ->
        state
    end
  end

  defp pump(state, acked) do
    with %{bytes: bytes} when bytes < @high_water <- Client.status(state.client),
         [_ | _] = events <- Outbox.read(state.outbox, acked, @batch) do
      send = for {seq, event} <- events, not skipped?(state.skip, seq, event), do: event
      if send != [], do: :ok = Client.push(state.client, send)
      {last, _} = List.last(events)
      :ok = Outbox.ack(state.outbox, last)
      state |> save_skip(Map.reject(state.skip, fn {_, seq} -> seq <= last end)) |> pump()
    else
      _ -> state
    end
  end

  defp save_skip(%{skip: skip} = state, skip), do: state

  # Written beside itself and moved into place, so a stop halfway leaves
  # the old one whole.
  defp save_skip(state, skip) do
    file = Path.join(state.dir, "skip.json")
    File.write!(file <> ".tmp", "")
    File.chmod!(file <> ".tmp", 0o600)
    File.write!(file <> ".tmp", Jason.encode!(skip))
    File.rename!(file <> ".tmp", file)
    %{state | skip: skip}
  end

  defp saved_skip(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "skip.json")),
         {:ok, %{} = skip} <- Jason.decode(text) do
      for {file, seq} <- skip, is_binary(file) and is_integer(seq), into: %{}, do: {file, seq}
    else
      _ -> %{}
    end
  end

  # An event made before its file was read again from the hub's place.
  defp skipped?(skip, seq, %Proto.Event{file: file}),
    do: file != "" and seq <= Map.get(skip, file, 0)
end
