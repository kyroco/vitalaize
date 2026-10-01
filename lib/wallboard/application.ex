defmodule Wallboard.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:wallboard, :start_board, true) do
        children(Wallboard.Settings.load!())
      else
        [
          {Phoenix.PubSub, name: Wallboard.PubSub},
          {Task.Supervisor, name: Wallboard.TaskSupervisor}
        ]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Wallboard.Supervisor)
  end

  # The database, then what fills it. The status recorder listens to the
  # session checks, so it starts before the pollers do.
  defp archive_children(%{archive: %{enabled: true} = a} = settings) do
    [
      {Wallboard.Store, path: a.path},
      Wallboard.Archive.StatusRecorder,
      Wallboard.Remote
    ] ++
      if(a.collect_local, do: [Wallboard.Archive.Collector], else: []) ++
      [Wallboard.Archive.GitHubCollector] ++
      if(a.advertise, do: [{Wallboard.Advertise, port: settings.port}], else: []) ++
      link_children(settings)
  end

  defp archive_children(_), do: []

  # The port collectors stream to. After the database, which is where what
  # they send goes. Then the pairing door, which hands out the certificates
  # that port asks for.
  defp link_children(settings) do
    if Wallboard.Link.hub?(settings) do
      dir = Wallboard.Link.Authority.dir(settings)

      [
        # Listens for what the port saves, so it starts first.
        Wallboard.Link.Sessions,
        {Wallboard.Link.Hub, dir: dir, port: settings.link.port},
        {Wallboard.Pairing.Door,
         dir: dir,
         link_port: settings.link.port,
         hub_name: Wallboard.Archive.Collector.machine(settings)}
      ]
    else
      []
    end
  end

  @doc """
  What runs for these settings. In the collector role that is the watcher,
  its outbox and the sender that streams it to the hub: no web server, no
  board, no GitHub, AWS or New Relic checks and no database. Any other
  role runs the board.
  """
  def children(%{role: :collector} = settings), do: collector_children(settings)
  def children(settings), do: board_children(settings)

  defp collector_children(settings) do
    [
      {Task.Supervisor, name: Wallboard.TaskSupervisor},
      {Wallboard.Collector.Outbox,
       dir: Path.join(settings.collector.dir, "outbox"),
       max_bytes: settings.collector.outbox_mb * 1_000_000},
      Wallboard.Collector.Watcher,
      # Sends the outbox to the hub, once this machine is paired with one.
      {Wallboard.Collector.Sender, dir: settings.collector.dir}
    ]
  end

  defp board_children(settings) do
    configure_endpoint(settings)
    new_relic? = settings.new_relic.enabled

    # Each source has its own poller. If one keeps failing, its panel shows
    # stale data with the reason; the others and the page carry on.
    pollers =
      [
        {Wallboard.Poller,
         name: :claude,
         source: Wallboard.Sources.Claude,
         interval_ms: settings.claude.poll_seconds * 1000},
        {Wallboard.Poller,
         name: :codex,
         source: Wallboard.Sources.Codex,
         interval_ms: settings.claude.poll_seconds * 1000,
         timeout_ms: 120_000},
        {
          Wallboard.Poller,
          # The time limit grows with the repositories in each poll's settings.
          name: :github,
          source: Wallboard.Sources.GitHub,
          interval_ms: settings.github.poll_seconds * 1000,
          timeout_ms: &Wallboard.Sources.GitHub.timeout_ms/1
        },
        # The first read of the transcripts can take a minute or two.
        {Wallboard.Poller,
         name: :usage,
         source: Wallboard.Sources.Usage,
         interval_ms: settings.usage.poll_seconds * 1000,
         timeout_ms: 600_000},
        # Runs every minute so turning the check on or off shows within the
        # minute; GitHub itself is asked once a day.
        {Wallboard.Poller, name: :release, source: Wallboard.Sources.Release, interval_ms: 60_000}
      ] ++
        if(Wallboard.Sources.DevPower.enabled?(settings),
          do: [
            {Wallboard.Poller,
             name: :dev_power,
             source: Wallboard.Sources.DevPower,
             interval_ms: settings.dev_power.poll_seconds * 1000}
          ],
          else: []
        ) ++
        if(Wallboard.Sources.Builds.enabled?(settings),
          do: [
            {Wallboard.Poller,
             name: :builds,
             source: Wallboard.Sources.Builds,
             interval_ms: settings.builds.poll_seconds * 1000}
          ],
          else: []
        ) ++
        if new_relic?,
          do: [
            {Wallboard.Poller,
             name: :new_relic,
             source: Wallboard.Sources.NewRelic,
             interval_ms: settings.new_relic.poll_seconds * 1000}
          ],
          else: []

    [
      {Phoenix.PubSub, name: Wallboard.PubSub},
      {Task.Supervisor, name: Wallboard.TaskSupervisor}
    ] ++
      archive_children(settings) ++
      if(new_relic?,
        # Reads the New Relic key once, in the background, so a 1Password
        # prompt never holds up the rest of the board. With page 2 turned
        # off, 1Password is never asked.
        do: [
          Supervisor.child_spec({Task, fn -> Wallboard.Secrets.load_new_relic(settings) end},
            id: :load_new_relic_key
          )
        ],
        else: []
      ) ++
      [
        %{
          id: Wallboard.Pollers,
          type: :supervisor,
          start:
            {Supervisor, :start_link,
             [pollers, [strategy: :one_for_one, max_restarts: 100, max_seconds: 60]]}
        },
        WallboardWeb.Endpoint,
        Supervisor.child_spec({Task, fn -> announce(settings) end}, id: :announce)
      ]
  end

  defp configure_endpoint(settings) do
    config =
      Application.get_env(:wallboard, WallboardWeb.Endpoint, [])
      |> Keyword.merge(
        server: true,
        http: [ip: {0, 0, 0, 0}, port: settings.port],
        url: [host: "localhost"],
        secret_key_base: Wallboard.Settings.secret_key_base(settings),
        check_origin: false
      )

    Application.put_env(:wallboard, WallboardWeb.Endpoint, config)
  end

  defp announce(settings) do
    query = if settings.token, do: "/?token=#{settings.token}", else: "/"

    for ip <- Wallboard.Network.lan_addresses() do
      Logger.info("Board is up: http://#{ip}:#{settings.port}#{query}")
    end

    if settings.token == nil,
      do: Logger.info("No token set, so anyone on this network can open the board.")

    case Wallboard.Alerts.channels(settings) do
      [] ->
        Logger.info("Alerts are off (no phone, Slack, ntfy or Pushover in settings).")

      channels ->
        Logger.info("Alerts go by #{Enum.map_join(channels, ", ", &Wallboard.Alerts.name/1)}.")
    end
  end

  # A planned stop: connected collectors are told the hub will be back, so
  # they wait a little before they try again, and get a moment to hear it.
  @impl true
  def prep_stop(state) do
    if Wallboard.Link.Hub.back_soon() > 0, do: Process.sleep(300)
    state
  end

  @impl true
  def config_change(changed, _new, removed) do
    WallboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
