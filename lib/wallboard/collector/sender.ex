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

  The collector's folder (`collector.dir` in settings) holds what pairing
  leaves there: `cert.pem`, `key.pem` and `ca.pem`, and `hub.json` with the
  hub's address, such as `{"host": "192.168.1.20", "link_port": 4748}`.
  Until all four are there nothing is sent, and the outbox keeps the
  events. The sender looks for them every few seconds, so a collector
  paired while it runs starts sending without a restart.

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
  is dropped unsent: the lines read again replace it. So after a dropout,
  a restart of either side, or a hub that lost some of what it had, the
  hub gets each file's lines in order with none missing, whatever was on
  its way before.

  Which events are dropped unsent is kept in `skip.json` in the collector's
  folder, so a collector that stops halfway through does not send them
  after it starts again.
  """

  use GenServer
  require Logger

  alias Wallboard.Collector.{Outbox, Proto, Watcher}
  alias Wallboard.Link.{Authority, Client}

  @tick_ms 500
  @batch 200
  @high_water 4_000_000

  def start_link(opts) do
    # `name: nil` starts one without a name, for tests.
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  What pairing left in the collector's folder `dir`:
  `{:ok, %{tls: %{cert_pem, key_pem, ca_pem}, host, port}}`, or `:error`
  while any of it is missing or cannot be read.
  """
  def paired(dir) do
    with {:ok, cert} <- File.read(Path.join(dir, "cert.pem")),
         {:ok, key} <- File.read(Path.join(dir, "key.pem")),
         {:ok, ca} <- File.read(Path.join(dir, "ca.pem")),
         {:ok, text} <- File.read(Path.join(dir, "hub.json")),
         {:ok, %{"host" => host, "link_port" => port}}
         when is_binary(host) and host != "" and is_integer(port) and port > 0 and port < 65_536 <-
           Jason.decode(text) do
      {:ok, %{tls: %{cert_pem: cert, key_pem: key, ca_pem: ca}, host: host, port: port}}
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
      client: nil,
      # The hub's positions still to go back to, and whether it has been
      # done at least once: nothing is sent before.
      resume: nil,
      ready?: false,
      # file => the outbox number up to which its events are not sent
      skip: %{},
      removed?: false,
      warned?: false
    }

    state = %{state | skip: saved_skip(state.dir)}

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state |> connect() |> rewind() |> pump()}
  end

  def handle_info({:wallboard_link, {:resume, points}}, state),
    do: {:noreply, %{state | resume: points} |> rewind() |> pump()}

  def handle_info({:wallboard_link, {:stored, _seq}}, state), do: {:noreply, pump(state)}

  def handle_info({:wallboard_link, :removed}, state) do
    Logger.warning("Collector: the hub removed this machine. Nothing more is sent.")
    {:noreply, %{state | removed?: true}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Never print events or certificates in a crash report.
  @impl true
  def format_status(status) do
    status
    |> Map.update(:state, nil, &Map.take(&1, [:dir, :ready?, :removed?]))
    |> Map.replace(:message, :not_shown)
    |> Map.replace(:log, [])
  end

  # ---------------------------------------------------------------------------

  # Starts the link's client once the collector is paired. The two live and
  # stop together.
  defp connect(%{client: nil} = state) do
    with {:ok, hub} <- paired(state.dir),
         %Proto.Hello{} = hello <- hello(state) do
      # Read here first: files that are there and are not a certificate
      # must not stop the collector.
      Authority.collector_tls(hub.tls)

      opts =
        Keyword.merge(
          [
            host: hub.host,
            port: hub.port,
            tls: hub.tls,
            hello: hello,
            buffer: Path.join(state.dir, "link.buffer"),
            listener: self()
          ],
          state.client_opts
        )

      {:ok, pid} = Client.start_link(opts)
      Logger.info("Collector: sending to the hub at #{hub.host}, port #{hub.port}.")
      %{state | client: pid}
    else
      _ -> state
    end
  rescue
    _ ->
      if not state.warned?,
        do: Logger.warning("Collector: the certificate files could not be read. Pair again.")

      %{state | warned?: true}
  end

  defp connect(state), do: state

  defp hello(state) do
    Watcher.hello(state.watcher)
  catch
    :exit, _ -> nil
  end

  # Goes back to the hub's place in each file. Until that has worked, no
  # event is handed on.
  defp rewind(%{resume: nil} = state), do: state

  defp rewind(state) do
    case Watcher.rewind(state.watcher, state.resume) do
      {:ok, files, seq} ->
        skip = Enum.reduce(files, state.skip, &Map.put(&2, &1, seq))
        state = save_skip(state, skip)
        :ok = Client.rewound(state.client, files)
        %{state | resume: nil, ready?: true}

      :retry ->
        state
    end
  catch
    :exit, _ -> state
  end

  defp pump(%{client: nil} = state), do: state
  defp pump(%{ready?: false} = state), do: state
  defp pump(%{removed?: true} = state), do: state
  defp pump(%{resume: points} = state) when points != nil, do: state

  defp pump(state) do
    with %{bytes: bytes} when bytes < @high_water <- Client.status(state.client),
         %{acked: acked} <- Outbox.stats(state.outbox),
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
