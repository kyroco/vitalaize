defmodule WallboardWeb.BoardLive do
  @moduledoc """
  The board: a header and status line that stay put, and under them tabs
  (Agents, Git, New Relic) laid side by side. The browser rotates between
  the tabs and handles taps and swipes; the server only sends what changed.

  Times go to the browser as timestamps, and the browser writes them in the
  time zone from settings ("1:27 PM", "4m ago"), so the clock and the ages
  tick without the server sending anything.
  """
  use WallboardWeb, :live_view

  alias Wallboard.{Mailbox, Poller, RunJobs, Runners, Settings, Store}
  alias Wallboard.Archive.{CiMinutes, Collector, Trends}
  alias Wallboard.Sources.{Builds, Claude, DevPower, GitHub}

  # How often the server redraws what depends on the time of day: the
  # 6-hour timeline and the "last 24 hours" counts.
  @tick_ms 30_000

  # The product's name, beside the brand at the top. It is fixed, not a
  # setting, so an old settings file can never show an old name.
  @product "VitalAIze"

  # The tabs under the status line, in the order the board rotates through
  # them. A new tab is one entry here and its section in render/1.
  @tabs [
    {:agents, "Agents"},
    {:git, "Git"},
    {:new_relic, "New Relic"}
  ]

  @doc "The tabs this board shows: New Relic only when it is turned on."
  def tabs(settings) do
    Enum.filter(@tabs, fn
      {:new_relic, _} -> settings.new_relic.enabled
      _ -> true
    end)
  end

  @impl true
  def mount(_params, session, socket) do
    # A screen left open across an update reconnects on its own but keeps the
    # old app.css and app.js, so it gets a full reload to fetch the new ones.
    if connected?(socket) and
         get_connect_params(socket)["asset_version"] != WallboardWeb.Layouts.asset_version() do
      {:ok, redirect(socket, to: "/")}
    else
      mount_board(socket, session)
    end
  end

  # The VitalAIze app or `vitalaize setup` saved a setting: a board left
  # open loads again, the way it does for new styles (see mount/3), so
  # the page, its clock and its page turning all start from the new
  # settings together.
  defp take_up_settings(socket) do
    now = Settings.get()

    cond do
      now == socket.assigns.settings -> socket
      reload_for?(socket.assigns.settings, now) -> redirect(socket, to: "/")
      true -> assign(socket, settings: now)
    end
  end

  @doc """
  Whether a board drawn from the settings `shown` must load again for the
  settings as they are `now`. A change to the list of repositories alone
  needs none: the Git tab reads that list on every check (see
  `derive_github/1`). So a Track in the mailbox does not reload the board
  under the owner's hand, with more asks still waiting there.
  """
  def reload_for?(shown, now),
    do: now != shown and put_in(now, [:github, :repos], shown.github.repos) != shown

  defp mount_board(socket, session) do
    settings = Settings.get()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Poller.topic())
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Mailbox.topic())
      :timer.send_interval(@tick_ms, :tick)
    end

    claude = Poller.snapshot(:claude)
    codex = Poller.snapshot(:codex)
    github = Poller.snapshot(:github)
    nr = Poller.snapshot(:new_relic)
    usage = Poller.snapshot(:usage)
    dev = Poller.snapshot(:dev_power)
    builds = Poller.snapshot(:builds)
    release = Poller.snapshot(:release)
    budget = Poller.snapshot(:budget)

    socket =
      socket
      |> assign(settings: settings, now: now(), product: @product, tabs: tabs(settings))
      |> assign(claude: claude.facts, claude_meta: claude.meta)
      |> assign(codex: codex.facts)
      |> assign(stream: Wallboard.Link.Sessions.cards())
      # What collectors say about the GitHub runners on their machines.
      |> assign(runners: Wallboard.Link.RunnerStates.states())
      |> assign(github: github.facts, github_meta: github.meta)
      |> assign(nr: nr.facts, nr_meta: nr.meta)
      |> assign(usage: usage.facts, usage_meta: usage.meta)
      |> assign(dev: dev.facts, dev_meta: dev.meta, dev_on?: DevPower.enabled?(settings))
      |> assign(builds: builds.facts, release: release.facts, budget: budget.facts)
      |> assign(
        archive_on?: settings.archive.enabled,
        machine: if(settings.archive.enabled, do: Collector.machine(settings)),
        session_tab: :live,
        archive: [],
        archive_counts: nil,
        archive_progress: nil,
        selected: nil,
        open_repo: nil,
        open_run: nil,
        run_view: nil,
        run_jobs: %{},
        repo_of: %{},
        back_ref: nil,
        trends: nil,
        trend_days: 14
      )
      # Who is looking decides whether the mailbox's buttons work (see
      # WallboardWeb.Auth.may_decide?/1). Only a live connection knows.
      |> assign(
        who:
          if(connected?(socket),
            do: WallboardWeb.Auth.who(socket, session),
            else: %{local?: false, token_hash: nil}
          ),
        mailbox: Mailbox.items(),
        mailbox_open?: false,
        mailbox_note: nil
      )
      |> derive_sessions()
      |> derive_github()

    {:ok, socket}
  end

  @impl true
  def handle_info({:source, :claude, facts, meta}, socket),
    do: {:noreply, socket |> assign(claude: facts, claude_meta: meta) |> derive_sessions()}

  def handle_info({:source, :codex, facts, _meta}, socket),
    do: {:noreply, socket |> assign(codex: facts) |> derive_sessions()}

  # Sessions that collectors stream from other machines.
  def handle_info({:stream, cards}, socket),
    do: {:noreply, socket |> assign(stream: cards) |> derive_sessions()}

  # The GitHub runners collectors report, `%{name => state}`.
  def handle_info({:runners, states}, socket) when is_map(states),
    do: {:noreply, socket |> assign(runners: states) |> derive_github()}

  def handle_info({:source, :github, facts, meta}, socket),
    do:
      {:noreply,
       socket
       |> assign(github: facts, github_meta: meta, now: now())
       |> derive_github()
       |> derive_run()}

  def handle_info({:source, :new_relic, facts, meta}, socket),
    do: {:noreply, assign(socket, nr: facts, nr_meta: meta)}

  def handle_info({:source, :usage, facts, meta}, socket),
    do: {:noreply, assign(socket, usage: facts, usage_meta: meta)}

  def handle_info({:source, :dev_power, facts, meta}, socket),
    do: {:noreply, assign(socket, dev: facts, dev_meta: meta)}

  def handle_info({:source, :builds, facts, _meta}, socket),
    do: {:noreply, assign(socket, builds: facts)}

  def handle_info({:source, :release, facts, _meta}, socket),
    do: {:noreply, assign(socket, release: facts)}

  def handle_info({:source, :budget, facts, _meta}, socket),
    do: {:noreply, assign(socket, budget: facts)}

  def handle_info({:source_meta, name, meta}, socket) do
    key =
      %{
        claude: :claude_meta,
        github: :github_meta,
        new_relic: :nr_meta,
        usage: :usage_meta,
        dev_power: :dev_meta
      }[name]

    {:noreply, if(key, do: assign(socket, key, meta), else: socket)}
  end

  def handle_info(:tick, socket) do
    {:noreply,
     socket |> take_up_settings() |> assign(now: now()) |> derive_sessions() |> derive_github()}
  end

  # A collector saved a round: an open Archive or Trends tab shows it.
  def handle_info({:archive, _}, socket) do
    case socket.assigns.session_tab do
      :archive -> {:noreply, load_archive(socket)}
      :trends -> {:noreply, load_trends(socket)}
      _ -> {:noreply, socket}
    end
  end

  # Something in the mailbox came or went.
  def handle_info({:mailbox, :changed}, socket),
    do: {:noreply, assign(socket, mailbox: Mailbox.items())}

  # Nobody touched the Archive tab for a while: back to the live sessions,
  # so a wall screen never hides a session that needs you. An open mailbox
  # closes with it.
  def handle_info({:back_to_live, ref}, %{assigns: %{back_ref: ref}} = socket),
    do:
      {:noreply,
       assign(socket,
         session_tab: :live,
         selected: nil,
         open_repo: nil,
         open_run: nil,
         run_view: nil,
         back_ref: nil,
         mailbox_open?: false,
         mailbox_note: nil
       )}

  def handle_info(_, socket), do: {:noreply, socket}

  @back_to_live_ms 5 * 60_000

  @impl true
  def handle_event(
        "session_tab",
        %{"tab" => "archive"},
        %{assigns: %{archive_on?: true}} = socket
      ),
      do: {:noreply, socket |> assign(session_tab: :archive) |> load_archive() |> touched()}

  def handle_event(
        "session_tab",
        %{"tab" => "trends"},
        %{assigns: %{archive_on?: true}} = socket
      ),
      do: {:noreply, socket |> assign(session_tab: :trends) |> load_trends() |> touched()}

  def handle_event("trend_days", %{"days" => days}, socket) when days in ["7", "14", "30"],
    do:
      {:noreply,
       socket |> assign(trend_days: String.to_integer(days)) |> load_trends() |> touched()}

  def handle_event("session_tab", _params, socket),
    do: {:noreply, assign(socket, session_tab: :live, selected: nil, back_ref: nil)}

  def handle_event(
        "open_session",
        %{"machine" => m, "id" => id},
        %{assigns: %{archive_on?: true}} = socket
      ) do
    selected =
      case Store.get_session(m, id) do
        nil -> %{missing: true, session_id: id}
        s -> with_ci(s)
      end

    {:noreply, socket |> assign(selected: selected) |> touched()}
  end

  def handle_event("open_session", _params, socket), do: {:noreply, socket}

  def handle_event("close_session", _params, socket),
    do: {:noreply, socket |> assign(selected: nil) |> touched()}

  # A repository's details, over the board like a session's. They follow
  # the live numbers while open.
  def handle_event("open_repo", %{"repo" => repo}, socket) do
    if Enum.any?(socket.assigns.git, &(&1.repo == repo)),
      do: {:noreply, socket |> assign(open_repo: repo) |> touched()},
      else: {:noreply, socket}
  end

  def handle_event("close_repo", _params, socket),
    do: {:noreply, socket |> assign(open_repo: nil) |> touched()}

  # One run's details, over the board or over its repository's details.
  # They follow the live checks while open. A tap may read a finished run's
  # jobs once more when the last read failed, never more than once.
  def handle_event("open_run", %{"repo" => repo, "id" => id}, socket) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %{} <- find_run(socket.assigns.github, repo, id) do
      jobs =
        Map.filter(socket.assigns.run_jobs, fn {{r, i, _}, v} ->
          r == repo and i == id and not match?({:error, _}, v)
        end)

      {:noreply,
       socket
       |> assign(open_run: %{repo: repo, id: id}, run_view: nil, run_jobs: jobs)
       |> derive_run()
       |> touched()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_run", _params, socket),
    do: {:noreply, socket |> assign(open_run: nil, run_view: nil) |> touched()}

  def handle_event("refresh_archive", _params, %{assigns: %{archive_on?: true}} = socket) do
    Collector.refresh()

    {:noreply,
     socket |> assign(archive_progress: %{Collector.progress() | running: true}) |> touched()}
  end

  def handle_event("mailbox_open", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(mailbox_open?: true, mailbox_note: nil, mailbox: Mailbox.items())
       |> touched()}

  def handle_event("mailbox_close", _params, socket),
    do: {:noreply, socket |> assign(mailbox_open?: false, mailbox_note: nil) |> touched()}

  # Approve, Refuse and the like. Looking at the mailbox is for anyone who
  # can see the board; deciding is for its owner.
  def handle_event("mailbox_act", %{"id" => id, "action" => action}, socket) do
    note =
      if WallboardWeb.Auth.may_decide?(socket.assigns.who) do
        case Mailbox.act(id, action) do
          :ok -> nil
          {:error, :gone} -> "That one was already decided, or it ran out."
          {:error, _} -> "That did not work just now. Try again in a moment."
        end
      else
        cannot_decide()
      end

    {:noreply, socket |> assign(mailbox: Mailbox.items(), mailbox_note: note) |> touched()}
  end

  def handle_event(_, _params, socket), do: {:noreply, socket}

  # A finished run's jobs, from the board's one reader of them (see
  # Wallboard.RunJobs), which reads each run once for every screen.
  @impl true
  def handle_async({:run_jobs, key}, result, socket) do
    got =
      case result do
        {:ok, {:ok, rows}} ->
          rows

        {:ok, {:error, why}} ->
          {:error, why}

        {:exit, reason} ->
          {:error, "the read stopped: #{inspect(reason)}"}
      end

    {:noreply,
     socket |> assign(run_jobs: Map.put(socket.assigns.run_jobs, key, got)) |> derive_run()}
  end

  defp cannot_decide do
    if Settings.get().token,
      do: "Open the board with its password to decide.",
      else: "Decide on the hub's own machine, or give the board a password in Settings first."
  end

  # Sessions still being saved show as loading under Claude and Codex, so a
  # half-filled chart never looks broken.
  defp load_trends(socket) do
    t = Trends.build(socket.assigns.settings, socket.assigns.trend_days)
    saving = if Collector.progress().running, do: "Loading…"
    loading = Map.merge(t.loading, %{claude: saving, codex: saving})
    assign(socket, trends: %{t | loading: loading})
  end

  defp load_archive(socket) do
    assign(socket,
      archive: Store.list_sessions(150),
      archive_counts: Store.counts(),
      archive_progress: Collector.progress()
    )
  end

  # Any tap keeps the Archive tab and the details open a while longer.
  defp touched(
         %{
           assigns: %{
             session_tab: :live,
             selected: nil,
             open_repo: nil,
             open_run: nil,
             mailbox_open?: false
           }
         } = socket
       ),
       do: assign(socket, back_ref: nil)

  defp touched(socket) do
    ref = make_ref()
    Process.send_after(self(), {:back_to_live, ref}, @back_to_live_ms)
    assign(socket, back_ref: ref)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # ---------------------------------------------------------------------------
  # Shaping the data for the page

  defp derive_sessions(socket) do
    %{settings: settings, now: now} = socket.assigns
    claude = (socket.assigns.claude && socket.assigns.claude.sessions) || []
    codex = (socket.assigns[:codex] && socket.assigns.codex.sessions) || []
    # A session shows once: this machine's own check comes first, then a
    # collector's stream.
    local_ids = MapSet.new(claude ++ codex, & &1.session_id)
    stream = Enum.reject(socket.assigns[:stream] || [], &MapSet.member?(local_ids, &1.session_id))
    sessions = Enum.map(claude, &Map.put(&1, :tool, :claude)) ++ codex ++ stream
    long = settings.claude.long_running_minutes

    sessions = Enum.map(sessions, &Map.put(&1, :long?, Claude.long_running?(&1, now, long)))

    # Each card names its repository, looked up once per folder.
    {sessions, repo_of} =
      Enum.map_reduce(sessions, socket.assigns.repo_of, fn s, known ->
        cwd = s[:cwd]
        known = if Map.has_key?(known, cwd), do: known, else: Map.put(known, cwd, repo_of(cwd))
        # A streamed session names its own repository: its folder is on
        # another machine.
        {Map.put(s, :repo, s[:repo] || known[cwd]), known}
      end)

    needs = sessions |> Enum.filter(&(&1.status == :needs)) |> Enum.sort_by(&unix(&1.since))
    working = sessions |> Enum.filter(&(&1.status == :working)) |> Enum.sort_by(&unix(&1.since))
    idle = sessions |> Enum.filter(&(&1.status == :idle)) |> Enum.sort_by(& &1.name)

    assign(socket,
      needs: needs,
      working: working,
      idle: idle,
      session_count: length(sessions),
      repo_of: repo_of
    )
  end

  # "api" for a folder in acme/api, or nil outside a GitHub checkout.
  defp repo_of(cwd) do
    case Wallboard.GitRemote.github_repo(cwd) do
      nil -> nil
      repo -> repo |> String.split("/") |> List.last()
    end
  end

  # Every repository, the ones with a column on the Git tab and the quiet
  # rest, and the first one's summary, which the Dev and Prod tiles read.
  # The repository list comes from the settings as they are now, like the
  # poller's, so one added or removed on the settings page shows without a
  # reload. A runner GitHub does not list takes its state from a collector
  # on its machine, when one reports it.
  defp derive_github(socket) do
    %{github: facts, now: now} = socket.assigns
    repos = GitHub.repos(facts, Settings.get(), now, socket.assigns[:runners] || %{})
    {columns, quiet} = GitHub.arrange(repos)

    assign(socket,
      git: repos,
      git_columns: columns,
      git_quiet: quiet,
      gh: repos |> List.first() |> then(&(&1 && &1.s))
    )
  end

  # The open run and its jobs. A run that leaves GitHub's last-day list
  # keeps what was last seen of it. Jobs come from the check that reads
  # running runs, from the archive, or from one read of that run alone.
  defp derive_run(%{assigns: %{open_run: nil}} = socket), do: assign(socket, run_view: nil)

  defp derive_run(%{assigns: %{open_run: %{repo: repo, id: id}}} = socket) do
    seen = socket.assigns.run_view && socket.assigns.run_view.run

    case find_run(socket.assigns.github, repo, id) || seen do
      nil ->
        assign(socket, open_run: nil, run_view: nil)

      run ->
        {socket, jobs} = run_jobs(socket, repo, run)

        assign(socket,
          run_view: %{repo: repo, run: run, jobs: jobs, listed: listed_runners(socket, repo)}
        )
    end
  end

  # The runners GitHub lists as the repository's own, now and before (see
  # Wallboard.Runners), so a job's line can say it ran on your machine.
  defp listed_runners(socket, repo) do
    now =
      for %{repo: ^repo, facts: %{runners: list}} <- (socket.assigns.github || %{})[:repos] || [],
          do: Runners.listed_names(list)

    saved = if Process.whereis(Store), do: Store.runner_names(repo), else: []
    Enum.uniq(List.flatten(now) ++ saved)
  end

  defp run_jobs(socket, repo, %{status: :completed} = run) do
    key = {repo, run.id, run[:attempt]}

    case socket.assigns.run_jobs[key] || saved_jobs(socket, key) do
      nil ->
        socket =
          socket
          |> assign(run_jobs: Map.put(socket.assigns.run_jobs, key, :loading))
          |> start_async({:run_jobs, key}, fn -> RunJobs.get(repo, run.id, run[:attempt]) end)

        {socket, :loading}

      jobs ->
        {assign(socket, run_jobs: Map.put(socket.assigns.run_jobs, key, jobs)), jobs}
    end
  end

  defp run_jobs(socket, repo, run) do
    case get_in(repo_facts(socket.assigns.github, repo) || %{}, [:jobs, run.id]) do
      %{list: list} -> {socket, list}
      _ -> {socket, if(run.status == :queued, do: :waiting, else: :pending)}
    end
  end

  defp saved_jobs(socket, {repo, id, attempt}) do
    if archive?(socket), do: Store.run_jobs(repo, id, attempt)
  end

  defp archive?(socket),
    do: socket.assigns.archive_on? and is_pid(Process.whereis(Wallboard.Store))

  @doc false
  # A run the Git tab lists, by its repository and id, with the words its
  # row shows.
  def find_run(github, repo, id) do
    case repo_facts(github, repo) do
      %{runs: runs} = facts ->
        (runs ++ (facts[:deploys] || []))
        |> Enum.find(&(&1.id == id))
        |> then(&(&1 && Map.merge(&1, %{what: GitHub.what(&1), took: GitHub.duration(&1)})))

      _ ->
        nil
    end
  end

  defp unix(nil), do: 0
  defp unix(dt), do: DateTime.to_unix(dt)

  # ---------------------------------------------------------------------------
  # Page

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="board"
      phx-hook="Board"
      data-keep="style"
      data-rotate={@settings.rotate_seconds}
      data-tz={@settings.timezone}
      data-pages={length(@tabs)}
    >
      <div class="frame">
        <.header
          brand={@settings.brand}
          title={@product}
          tabs={@tabs}
          metas={[@claude_meta, @github_meta]}
          release={@release}
          mailbox={length(@mailbox)}
        />
        <.needs_banner needs={@needs} />
        <.budget_banner over={budget_over(@budget)} needs_archive={budget_needs_archive?(@budget)} />
        <.tiles
          repos={@git}
          meta={@github_meta}
          dev={if @dev_on?, do: dev_power_tile(@dev, @dev_meta)}
          gh={@gh}
          builds={@builds && Builds.compare(@builds)}
        />
        <%!-- The browser marks the tab it shows; taps and the rotation move
             the track under it. --%>
        <nav class="board-tabs" role="tablist" aria-label="Tabs">
          <button
            :for={{{key, label}, i} <- Enum.with_index(@tabs)}
            class="board-tab"
            role="tab"
            data-goto={i}
            data-tab={key}
            data-keep="class aria-selected"
            aria-selected="false"
          >
            {label}
          </button>
        </nav>
        <div class="viewport">
          <%!-- One section per tab, in the order of @tabs. --%>
          <div id="track" class="track" data-keep="style">
            <section :if={tab?(@tabs, :agents)} class="page page-agents" aria-label="Agents">
              <.sessions
                needs={@needs}
                working={@working}
                idle={@idle}
                count={@session_count}
                meta={@claude_meta}
                details={(@usage && @usage.sessions) || %{}}
                problems={(@claude && @claude.problems) || []}
                tab={@session_tab}
                archive_on?={@archive_on?}
                archive={@archive}
                archive_counts={@archive_counts}
                archive_progress={@archive_progress}
                machine={@machine}
                trends={@trends}
                trend_days={@trend_days}
                usage={@usage}
                usage_meta={@usage_meta}
              />
            </section>
            <section :if={tab?(@tabs, :git)} class="page page-git" aria-label="Git">
              <.git_tab columns={@git_columns} quiet={@git_quiet} now={@now} meta={@github_meta} />
            </section>
            <section
              :if={tab?(@tabs, :new_relic)}
              class="page page-new_relic"
              aria-label={@settings.brand.page2_title}
            >
              <.new_relic nr={@nr} meta={@nr_meta} now={@now} slots={@settings.new_relic.slots} />
            </section>
          </div>
        </div>
      </div>
      <.session_detail :if={@selected} s={@selected} settings={@settings} />
      <.repo_detail
        :if={@open_repo && Enum.find(@git, &(&1.repo == @open_repo))}
        r={Enum.find(@git, &(&1.repo == @open_repo))}
        facts={repo_facts(@github, @open_repo)}
        meta={@github_meta}
      />
      <.run_detail :if={@run_view} v={@run_view} />
      <WallboardWeb.MailboxPanel.panel
        :if={@mailbox_open?}
        items={@mailbox}
        note={@mailbox_note}
        may_decide?={WallboardWeb.Auth.may_decide?(@who)}
        cannot={cannot_decide()}
      />
    </div>
    """
  end

  defp repo_facts(%{repos: entries}, repo),
    do: Enum.find_value(entries, &(&1.repo == repo && &1.facts))

  defp repo_facts(_, _), do: nil

  defp tab?(tabs, key), do: List.keymember?(tabs, key, 0)

  # ---------------------------------------------------------------------------
  # Pieces

  attr :brand, :map, required: true
  attr :title, :string, required: true
  attr :tabs, :list, required: true
  attr :metas, :list, required: true
  # A newer release than this board runs, or nil (see Wallboard.Sources.Release).
  attr :release, :map, default: nil
  # How many things wait in the mailbox.
  attr :mailbox, :integer, default: 0

  # The name, then the switches and the clock. The browser owns which page
  # dot is on and whether Pin is on, so those attributes survive updates.
  defp header(assigns) do
    ~H"""
    <header class="header">
      <img :if={@brand.logo} class="logo" src="/brand/logo" alt={@brand.name} />
      <div :if={!@brand.logo} class="wordmark">{@brand.name}</div>
      <div class="divider"></div>
      <div class="page-title">{@title}</div>
      <div class="grow"></div>
      <button
        class="link-button header-link theme-toggle"
        data-theme-toggle
        aria-label="Switch light or dark"
      >
        <svg
          class="icon-moon"
          width="14"
          height="14"
          viewBox="0 0 24 24"
          fill="currentColor"
          aria-hidden="true"
        ><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" /></svg>
        <svg
          class="icon-sun"
          width="14"
          height="14"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          aria-hidden="true"
        ><circle cx="12" cy="12" r="4.5" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" /></svg>
        <span class="theme-word"></span>
      </button>
      <a
        :if={@release}
        class="link-button header-link update-note"
        href={@release.url}
        target="_blank"
        rel="noopener noreferrer"
      >
        Version {@release.version} is available
      </a>
      <a class="link-button header-link" href="/settings">Settings</a>
      <%!-- With one tab there is nothing to rotate, so no pin and no dots. --%>
      <button
        :if={length(@tabs) > 1}
        class="pin"
        data-pin
        data-keep="class aria-pressed"
        aria-pressed="false"
        aria-label="Pin this tab"
      >
        <svg
          width="20"
          height="20"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M9 4h6l-1 6 4 4H6l4-4z"></path>
          <path d="M12 14v7"></path>
        </svg>
        <span class="pin-label pin-off">Pin</span><span class="pin-label pin-on">Pinned</span>
      </button>
      <nav :if={length(@tabs) > 1} class="dots" aria-label="Tabs">
        <button
          :for={{{_key, label}, i} <- Enum.with_index(@tabs)}
          data-goto={i}
          class="dot"
          data-keep="class"
          aria-label={label}
        ></button>
      </nav>
      <button
        class="mailbox-button"
        phx-click="mailbox_open"
        aria-label={
          if @mailbox == 0, do: "Mailbox, nothing waiting", else: "Mailbox, #{@mailbox} waiting"
        }
      >
        <svg
          width="26"
          height="22"
          viewBox="0 0 26 22"
          fill="none"
          stroke="currentColor"
          stroke-width="1.8"
          aria-hidden="true"
        ><rect x="1" y="5" width="24" height="16" rx="2" /><path d="M1 7l12 8 12-8" /></svg>
        <span :if={@mailbox > 0} class="mailbox-count">{@mailbox}</span>
      </button>
      <div class="clockbox" data-fullscreen>
        <div class="clock" data-clock></div>
        <div class="dateline">
          <span data-today></span> · updated <.ago at={oldest(@metas)} stale={stale_after(@metas)} />
        </div>
      </div>
    </header>
    """
  end

  # The oldest "last good data" among the sources on a page.
  defp oldest(metas) do
    metas
    |> Enum.map(& &1.fetched_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp stale_after(metas), do: metas |> Enum.map(&stale_seconds/1) |> Enum.max(fn -> 60 end)

  defp stale_seconds(%{interval: ms}) when is_integer(ms), do: div(ms * 3, 1000) + 10
  defp stale_seconds(_), do: 60

  attr :at, :any, required: true
  attr :stale, :integer, default: nil
  attr :fmt, :string, default: "ago"
  attr :class, :string, default: nil
  attr :rest, :global

  defp ago(assigns) do
    ~H"""
    <time
      :if={@at}
      class={@class}
      data-ts={DateTime.to_iso8601(@at)}
      data-fmt={@fmt}
      data-stale={@stale}
      {@rest}
    ></time><span
      :if={!@at}
      class={@class}
    >never</span>
    """
  end

  attr :meta, :map, required: true

  # "· 4s ago" after a panel heading, or why the panel is stale.
  defp freshness(assigns) do
    ~H"""
    <span class="fresh">
      · <.ago at={@meta.fetched_at} stale={stale_seconds(@meta)} />
      <span :if={@meta.error} class="stale-note">· stale: {@meta.error}</span>
    </span>
    """
  end

  @doc false
  # The limits the budget poller last found passed; none before its first check.
  def budget_over(%{over: over}), do: over
  def budget_over(_), do: []

  @doc false
  # True when a budget limit is set but the archive is off, so none is checked.
  def budget_needs_archive?(%{needs_archive: true}), do: true
  def budget_needs_archive?(_), do: false

  attr :over, :list, required: true
  attr :needs_archive, :boolean, default: false

  # The budget limits passed in their day or week (see Wallboard.Sources.Budget),
  # or, with the archive off, why none is checked.
  @doc false
  def budget_banner(assigns) do
    ~H"""
    <section :if={@needs_archive} class="budget-banner" aria-label="Budget limits">
      <span class="bb-kicker">Budget</span>
      <span class="bb-items">
        Budget limits are set, but the archive is off, so none is checked.
        Set archive enabled to true in settings.exs.
      </span>
    </section>
    <section :if={@over != []} class="budget-banner" aria-label="Over budget">
      <span class="bb-kicker">Over budget</span>
      <span class="bb-items">
        <%= for {item, i} <- Enum.with_index(@over) do %>
          <span :if={i > 0}> · </span>{Wallboard.Sources.Budget.describe(item)}
        <% end %>
      </span>
    </section>
    """
  end

  attr :needs, :list, required: true

  defp needs_banner(assigns) do
    ~H"""
    <section :if={@needs != []} class="needs-banner" role="alert" aria-label="Needs you">
      <svg
        width="28"
        height="28"
        viewBox="0 0 28 28"
        fill="none"
        stroke="currentColor"
        stroke-width="2.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="M14 4l11 19H3z"></path><path d="M14 11v6"></path><path d="M14 20.5v.5"></path>
      </svg>
      <%= case @needs do %>
        <% [one] -> %>
          <span class="nb-kicker">Needs you</span>
          <span class="nb-name">{one.name}<span :if={one.account} class="nb-acct"> · {one.account}</span></span>
          <span class="nb-why">{one.why}</span>
          <span class="nb-age">waiting <.ago at={one.since} fmt="for" /></span>
        <% many -> %>
          <span class="nb-kicker">{length(many)} need you</span>
          <span class="nb-why">
            <%= for {s, i} <- Enum.with_index(many) do %>
              <span :if={i > 0}> · </span><b>{s.name}</b> {short_why(s.why)}
            <% end %>
          </span>
          <span class="nb-age">oldest waiting <.ago at={hd(many).since} fmt="for" /></span>
      <% end %>
    </section>
    """
  end

  defp short_why(nil), do: ""

  defp short_why(why) do
    why = why |> String.split(~r/(?<=[.?!])\s/, parts: 2) |> hd()
    if String.length(why) > 70, do: String.slice(why, 0, 68) <> "…", else: why
  end

  # ---------------------------------------------------------------------------
  # Status tiles

  # Every repository (see GitHub.repos/3); the tiles add them up.
  attr :repos, :list, required: true
  # The first repository's summary, which Dev and Prod read.
  attr :gh, :map, default: nil
  attr :meta, :map, required: true
  # The Dev tile from AWS (awake or asleep), or nil to show the last deploy.
  attr :dev, :map, default: nil
  # Whether prod runs dev's build (:same, :different, :unknown), or nil when
  # that is not read from AWS.
  attr :builds, :atom, default: nil

  defp tiles(assigns) do
    assigns = assign(assigns, t: GitHub.totals(assigns.repos))

    ~H"""
    <section class="tiles" aria-label="Status">
      <%= if Enum.any?(@repos, & &1.s) do %>
        <.tile label="Main" {main_tile(@repos, @t)} />
        <.tile label="Merge queue" {queue_tile(@repos, @t)} />
        <.tile label="Running" {running_tile(@repos, @t)} />
        <.tile label="Failed · 24h" {failed_tile(@repos, @t)} />
        <.tile :if={@gh} label="Dev" {@dev || dev_tile(@gh.dev)} />
        <.tile :if={@gh} label="Prod" {prod_tile(@gh.prod, @builds)} />
        <.tile :if={!@gh} label="Dev" {@dev || %{value: "Unknown", sub: "loading"}} />
        <.tile :if={!@gh} label="Prod" value="Unknown" sub="loading" />
      <% else %>
        <.tile
          :for={label <- ["Main", "Merge queue", "Running", "Failed · 24h", "Dev", "Prod"]}
          label={label}
          value="Loading"
          sub={@meta.error || "reading GitHub"}
        />
      <% end %>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :tone, :atom, default: :muted
  attr :ring, :boolean, default: false
  attr :loud, :boolean, default: false
  attr :sub, :string, default: nil
  attr :at, :any, default: nil
  attr :tail, :string, default: nil

  # One cell: the label, then a dot and the value, then a short note.
  defp tile(assigns) do
    ~H"""
    <div class="tile">
      <span class="kicker">{@label}</span>
      <span class="tile-main">
        <span class={["dot8", @tone, @ring && "ring"]}></span>
        <span class={["tile-value", @loud && "loud"]}>{@value}</span>
      </span>
      <span class="tile-sub">{@sub}<.ago :if={@at} at={@at} fmt="clock" />{@tail}</span>
    </div>
    """
  end

  # With one repository the tiles read as they always did. With more, each
  # adds up every repository and names the ones that matter.
  defp main_tile([%{s: %{main: nil}} = one], _t),
    do: %{value: "Unknown", sub: no_main_run(one)}

  defp main_tile([one], _t), do: main_tile(one.s && one.s.main)

  defp main_tile(_repos, t) do
    value = "#{length(t.green)} of #{t.count} green"

    case {t.red, t.unknown} do
      {[one], _} ->
        %{
          value: value,
          tone: :bad,
          ring: true,
          sub: "#{one.name} failed ",
          at: one.s.main.updated_at
        }

      {[_ | _] = red, _} ->
        %{value: value, tone: :bad, ring: true, sub: "#{names(red)} failed"}

      {[], []} ->
        latest = t.green |> Enum.map(& &1.s.main.updated_at) |> Enum.max(DateTime)
        %{value: value, tone: :ok, sub: "last ", at: latest}

      {[], unknown} ->
        %{value: value, sub: main_unknown_note(unknown)}
    end
  end

  # Why main's state is not known. A repository with a gate workflow waits
  # for a gate run; one without waits for a run a push to main started.
  defp no_main_run(%{s: %{main_from: :runs}}), do: "no push to main ran today"
  defp no_main_run(_repo), do: "no gate run today"

  @doc false
  # The status line's note for the repositories whose main is not known,
  # each named under its own reason.
  def main_unknown_note(repos) do
    repos
    |> Enum.group_by(&no_main_run/1)
    |> Enum.sort()
    |> Enum.map_join("; ", fn {why, group} -> "#{names(group)}: #{why}" end)
  end

  defp main_tile(nil), do: %{value: "Unknown", sub: "no gate run today"}

  defp main_tile(run) do
    if run.conclusion == "success",
      do: %{value: "Green", tone: :ok, sub: "", at: run.updated_at},
      else: %{
        value: "Red",
        tone: :bad,
        ring: true,
        loud: true,
        sub: "",
        at: run.updated_at
      }
  end

  defp queue_tile(_repos, %{queued: []}), do: %{value: "Empty"}

  defp queue_tile([_], %{queued: [%{s: %{queue: [first | _] = queue}}]}),
    do: %{value: "#{length(queue)} waiting", tone: :info, sub: "next ##{first.pr}"}

  defp queue_tile(_repos, %{queued: queued}) do
    total = queued |> Enum.map(&length(&1.s.queue)) |> Enum.sum()
    next = Enum.map_join(queued, ", ", &"#{&1.name} ##{hd(&1.s.queue).pr}")
    %{value: "#{total} waiting", tone: :info, sub: next}
  end

  defp running_tile(_repos, %{running: []}), do: %{value: "0"}

  defp running_tile([_], %{running: [%{s: %{running: running}}]}) do
    names = running |> Enum.map(&running_name/1) |> Enum.uniq() |> Enum.join(", ")
    %{value: "#{length(running)}", tone: :warn, ring: true, sub: names}
  end

  defp running_tile(_repos, %{running: repos}) do
    total = repos |> Enum.map(&length(&1.s.running)) |> Enum.sum()
    %{value: "#{total}", tone: :warn, ring: true, sub: "in #{names(repos)}"}
  end

  defp running_name(%{pr: pr, name: name}) when is_integer(pr), do: "#{name} on ##{pr}"
  defp running_name(%{name: name}), do: name

  defp failed_tile(_repos, %{failures: []}), do: %{value: "0", tone: :ok}

  defp failed_tile(repos, %{failures: [latest | _] = failures}) do
    %{
      value: "#{length(failures)}",
      tone: :bad,
      ring: true,
      loud: true,
      sub: if(length(repos) > 1, do: "last #{latest.repo_name}, ", else: "last "),
      at: latest.updated_at
    }
  end

  # "web", "web and api", "web, api and docs".
  defp names(repos) do
    case Enum.map(repos, & &1.name) do
      [one] -> one
      many -> Enum.join(Enum.drop(many, -1), ", ") <> " and " <> List.last(many)
    end
  end

  # Dev's power state from AWS. While a read fails, the last good state stays
  # up with the reason, like every other panel.
  @doc false
  def dev_power_tile(nil, meta),
    do: %{value: "Checking", sub: meta.error || "reading AWS"}

  def dev_power_tile(facts, meta) do
    wanted = Enum.filter(facts.services, &(&1.desired > 0))
    up = Enum.count(wanted, &(&1.running >= &1.desired))

    tile =
      case DevPower.state(facts) do
        :awake ->
          %{value: "Awake", tone: :ok, sub: "#{length(wanted)} services up"}

        :asleep ->
          %{value: "Asleep", tone: :info, sub: "wakes on deploy"}

        :waking ->
          sub =
            if facts.database == "available",
              do: "#{up} of #{length(wanted)} services up",
              else: "database starting"

          %{value: "Waking", tone: :warn, ring: true, sub: sub}

        :falling_asleep ->
          %{value: "Going to sleep", tone: :warn, sub: ""}

        :mixed ->
          %{
            value: "Half awake",
            tone: :bad,
            ring: true,
            loud: true,
            sub: "database #{facts.database}, #{up} of #{length(wanted)} up"
          }
      end

    if meta.error, do: %{tile | sub: "stale: " <> meta.error}, else: tile
  end

  defp dev_tile(%{latest: nil}), do: %{value: "Unknown", sub: "none found"}

  defp dev_tile(%{latest: %{status: s} = run}) when s != :completed,
    do: %{
      value: "Deploying",
      tone: :warn,
      ring: true,
      sub: "started ",
      at: run.started_at
    }

  defp dev_tile(%{latest: %{conclusion: "success"} = run}),
    do: %{value: "Deployed", tone: :ok, sub: "", at: run.updated_at}

  defp dev_tile(%{latest: run}),
    do: %{
      value: "Failed",
      tone: :bad,
      ring: true,
      loud: true,
      sub: "",
      at: run.updated_at
    }

  defp prod_tile(%{latest: nil}, _dev), do: %{value: "Unknown", sub: "none found"}

  defp prod_tile(%{latest: %{status: s} = run}, _dev) when s != :completed,
    do: %{
      value: "Deploying",
      tone: :warn,
      ring: true,
      sub: "started ",
      at: run.started_at
    }

  defp prod_tile(%{latest: %{conclusion: c} = run}, _dev) when c not in ["success", "cancelled"],
    do: %{
      value: "Failed",
      tone: :bad,
      ring: true,
      loud: true,
      sub: "",
      at: run.updated_at
    }

  defp prod_tile(%{last_success: nil}, _dev),
    do: %{value: "Unknown", sub: "no successful deploy"}

  # Behind or current is decided by the builds each one runs, not by the
  # commits their deploy runs recorded (see Wallboard.Sources.Builds).
  defp prod_tile(%{last_success: _}, :different),
    do: %{value: "Behind", tone: :warn, sub: "dev has a newer build"}

  defp prod_tile(%{last_success: prod}, :same),
    do: %{value: "Current", tone: :ok, sub: "same build as dev · ", at: prod.updated_at}

  defp prod_tile(%{last_success: prod}, _builds),
    do: %{value: "Deployed", tone: :ok, sub: "", at: prod.updated_at}

  # ---------------------------------------------------------------------------
  # Claude sessions

  attr :needs, :list, required: true
  attr :working, :list, required: true
  attr :idle, :list, required: true
  attr :count, :integer, required: true
  attr :meta, :map, required: true
  attr :details, :map, required: true
  attr :problems, :list, required: true
  attr :tab, :atom, default: :live
  attr :archive_on?, :boolean, default: false
  attr :archive, :list, default: []
  attr :archive_counts, :map, default: nil
  attr :archive_progress, :map, default: nil
  attr :machine, :string, default: nil
  attr :trends, :map, default: nil
  attr :trend_days, :integer, default: 14
  attr :usage, :map, default: nil
  attr :usage_meta, :map, default: nil

  defp sessions(assigns) do
    ~H"""
    <section class="sessions" aria-label="Claude sessions">
      <div class="heading-row">
        <h2 :if={!@archive_on?} class="kicker">Claude sessions · {@count}</h2>
        <div :if={@archive_on?} class="tabs" role="tablist">
          <button
            class={["tab", @tab == :live && "on"]}
            role="tab"
            phx-click="session_tab"
            phx-value-tab="live"
          >
            Live · {@count}
          </button>
          <button
            class={["tab", @tab == :archive && "on"]}
            role="tab"
            phx-click="session_tab"
            phx-value-tab="archive"
          >
            Archive{if @archive_counts, do: " · #{thousands(@archive_counts.total)}"}
          </button>
          <button
            class={["tab", @tab == :trends && "on"]}
            role="tab"
            phx-click="session_tab"
            phx-value-tab="trends"
          >
            Trends
          </button>
        </div>
        <%= if @tab == :live do %>
          <span :if={@count > 0} class="counts">
            <b class="alert-ink">{length(@needs)}</b>
            need you · <b>{length(@working)}</b>
            working · <b>{length(@idle)}</b>
            idle
          </span>
          <.freshness meta={@meta} />
        <% end %>
        <.archive_status
          :if={@tab == :archive}
          counts={@archive_counts}
          progress={@archive_progress}
        />
        <span class="grow"></span>
        <div :if={@tab == :trends} class="range">
          <button
            :for={d <- [7, 14, 30]}
            class={["tab", @trend_days == d && "on"]}
            phx-click="trend_days"
            phx-value-days={d}
          >
            {d} days
          </button>
        </div>
      </div>
      <div :for={p <- @problems} class="stale-note small">Could not read {p}</div>

      <%= if @tab == :live do %>
        <%!-- Every session gets a full card, needs-you first. When there are
             more than fit, the cards scroll rather than hide. --%>
        <div class="card-grid">
          <.session_card
            :for={s <- @needs ++ @working ++ @idle}
            s={s}
            d={s[:detail] || @details[Map.get(s, :session_id)]}
            machine={@archive_on? && (s[:machine] || @machine)}
          />
        </div>
        <div :if={@count == 0} class="empty-box">No Claude sessions running.</div>
      <% end %>
      <.trends
        :if={@tab == :trends && @trends}
        t={@trends}
        usage={@usage}
        usage_meta={@usage_meta}
      />
      <%= if @tab == :archive do %>
        <div class="card-grid">
          <.archive_card
            :for={a <- @archive}
            a={a}
            live?={a.session_id in Enum.map(@needs ++ @working ++ @idle, & &1.session_id)}
            local={@machine}
          />
        </div>
        <div :if={@archive == []} class="empty-box">
          No sessions saved yet. The first save runs in the background after the board starts.
        </div>
      <% end %>
    </section>
    """
  end

  attr :t, :map, required: true
  attr :usage, :map, default: nil
  attr :usage_meta, :map, default: nil

  # One card per metric, one bar per day, grouped by where the numbers come from.
  defp trends(assigns) do
    ~H"""
    <div class="card-grid trend-grid">
      <div :if={@usage_meta} class="trend-wide">
        <.token_trend usage={@usage} meta={@usage_meta} />
      </div>
      <%= if @t[:compare] not in [nil, []] do %>
        <h3 class="kicker trend-group">
          <span class="dot8 g-claude"></span> Claude <span class="vs">vs</span>
          <span class="dot8 g-codex"></span> Codex
        </h3>
        <div class="compare-grid">
          <.compare_card :for={c <- @t.compare} c={c} days={@t.days} />
        </div>
      <% end %>
      <%= for {group, label} <- [
                shipped: "Shipped",
                claude: "Claude",
                codex: "Codex",
                korium: "Korium",
                github: "GitHub"
              ],
              Enum.any?(@t.cards, &(&1.group == group)) do %>
        <h3 class="kicker trend-group">
          <span class={["dot8", "g-#{group}"]}></span> {label}
          <span :if={@t[:loading][group]} class="trend-loading">{@t.loading[group]}</span>
        </h3>
        <div
          :for={c <- Enum.filter(@t.cards, &(&1.group == group))}
          class={["trend-card", "g-#{group}"]}
        >
          <span class="kicker">{c.label}</span>
          <div class="row baseline">
            <span class="trend-value">{trend_value(c.fmt, c.value)}</span>
            <span class={["trend-change", change_tone(c)]}>{change_text(c.change)}</span>
          </div>
          <span :if={c.sub} class="stat-note">{c.sub}</span>
          <%!-- Each day is a full-height column, so a hover or a tap anywhere
               above a short bar still finds it; app.js shows its data-tip. --%>
          <div class="spark trend-spark">
            <span
              :for={{v, d} <- Enum.zip(c.series, @t.days)}
              class="day"
              data-tip={bar_tip(c, d, v, List.last(@t.days))}
            >
              <span
                class={["sp", is_nil(v) && "empty", d == List.last(@t.days) && "today"]}
                style={"height: #{bar_height(v, c.series)}%"}
              ></span>
            </span>
            <span
              :if={average_height(c.series)}
              class="avg-line"
              style={"bottom: #{average_height(c.series)}%"}
            ></span>
          </div>
          <div class="trend-days" aria-hidden="true">
            <span :for={{d, i} <- Enum.with_index(@t.days)}>{day_mark(d, i, length(@t.days))}</span>
          </div>
        </div>
      <% end %>
    </div>
    <p class="trend-note">
      {day_label(List.first(@t.days))} to {day_label(List.last(@t.days))} · change is against the {length(
        @t.days
      )} days before, when those are saved<span :if={@t.history_start}>
        (saved since {day_label(@t.history_start)})</span>. Faded bar: today so far. Dashed line: the average day.
      Session numbers count on the day a session last worked, pull requests on the day they merged.
    </p>
    """
  end

  attr :c, :map, required: true
  attr :days, :list, required: true

  # One measure for both tools: a Claude bar and a Codex bar for each day, on
  # one scale, with each tool's total for the period above.
  defp compare_card(assigns) do
    top =
      assigns.c.series
      |> Enum.flat_map(fn {a, b} -> [a, b] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)

    assigns = assign(assigns, top: top, today: List.last(assigns.days))

    ~H"""
    <div class="trend-card compare-card">
      <span class="kicker">{@c.label}</span>
      <div class="compare-totals">
        <span class="ct g-claude">
          <.tool_icon tool={:claude} class="tool-icon small" />
          <b>{trend_value(@c.fmt, @c.claude)}</b> Claude
        </span>
        <span class="ct g-codex">
          <.tool_icon tool={:codex} class="tool-icon small" />
          <b>{trend_value(@c.fmt, @c.codex)}</b> Codex
        </span>
      </div>
      <div class="spark trend-spark compare-spark">
        <span
          :for={{{a, b}, d} <- Enum.zip(@c.series, @days)}
          class="day pair"
          data-tip={"#{day_label(d)}#{if d == @today, do: " so far"}: Claude #{trend_value(@c.fmt, a)} · Codex #{trend_value(@c.fmt, b)}"}
        >
          <span
            class={["sp", "g-claude-bar", d == @today && "today"]}
            style={"height: #{pair_height(a, @top)}%"}
          ></span>
          <span
            class={["sp", "g-codex-bar", d == @today && "today"]}
            style={"height: #{pair_height(b, @top)}%"}
          ></span>
        </span>
      </div>
      <div class="trend-days" aria-hidden="true">
        <span :for={{d, i} <- Enum.with_index(@days)}>{day_mark(d, i, length(@days))}</span>
      </div>
    </div>
    """
  end

  defp pair_height(nil, _), do: 0
  defp pair_height(_, top) when top <= 0, do: 0
  defp pair_height(v, top), do: max(round(v * 100 / top), if(v > 0, do: 4, else: 0))

  defp bar_tip(card, day, value, today) do
    so_far = if day == today, do: " so far", else: ""
    avg = average(card.series)
    base = "#{day_label(day)}#{so_far}: #{trend_value(card.fmt, value)}"
    if avg, do: base <> " · average #{trend_value(card.fmt, avg)}", else: base
  end

  # The day of the month under each bar. Past 14 days only every third one
  # fits, counted back from today so today always has its number.
  defp day_mark(day, i, count) do
    step = if count > 14, do: 3, else: 1
    if rem(count - 1 - i, step) == 0, do: day.day, else: ""
  end

  defp trend_value(_fmt, nil), do: "-"
  defp trend_value(:tokens, v), do: short_tokens(v)
  defp trend_value(:money, v), do: money(v)
  defp trend_value(:count, v), do: thousands(v)
  defp trend_value(:pct, v) when v < 10, do: :erlang.float_to_binary(v / 1, decimals: 1) <> "%"
  defp trend_value(:pct, v), do: "#{round(v)}%"
  defp trend_value(:minutes, v), do: :erlang.float_to_binary(v / 1, decimals: 1) <> " min"
  defp trend_value(:hours, v), do: "#{thousands(round(v))} h"

  defp change_text(nil), do: "no earlier data"
  defp change_text(c) when abs(c) < 0.5, do: "no change"
  defp change_text(c), do: if(c < 0, do: "▼ ", else: "▲ ") <> "#{round(abs(c))}%"

  # Green when the number moved the way you want, red when it did not.
  defp change_tone(%{change: nil}), do: "muted-ink"
  defp change_tone(%{change: c}) when abs(c) < 0.5, do: "muted-ink"
  defp change_tone(%{change: c, good: :up}), do: if(c > 0, do: "ok-ink", else: "bad-ink")
  defp change_tone(%{change: c, good: :down}), do: if(c < 0, do: "ok-ink", else: "bad-ink")

  # The average of the days with data, and where it sits on the card's bars.
  # Today is left out: it is not over yet.
  defp average(series) do
    days = series |> Enum.drop(-1) |> Enum.reject(&is_nil/1)
    if length(days) >= 2, do: Enum.sum(days) / length(days)
  end

  defp average_height(series) do
    case average(series) do
      nil ->
        nil

      avg ->
        top = series |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)
        if top > 0, do: Float.round(avg * 100 / top, 1)
    end
  end

  defp bar_height(nil, _), do: 0

  defp bar_height(v, series) do
    top = series |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)
    if top > 0, do: max(round(v * 100 / top), if(v > 0, do: 4, else: 0)), else: 0
  end

  @months ~w(Jan Feb March April May June July Aug Sept Oct Nov Dec)
  defp day_label(nil), do: ""
  defp day_label(%Date{month: m, day: d}), do: "#{Enum.at(@months, m - 1)} #{d}"

  attr :counts, :map, default: nil
  attr :progress, :map, default: nil

  # "Saved 9:40 AM · 12 deleted · Refresh", or the progress of a save round.
  defp archive_status(assigns) do
    ~H"""
    <span class="counts">
      <%= cond do %>
        <% @progress && @progress.running && @progress.total > 0 -> %>
          Saving {@progress.done} of {@progress.total}…
        <% @progress && @progress.running -> %>
          Looking for new sessions…
        <% @counts && @counts.last -> %>
          saved <.ago at={DateTime.from_unix!(@counts.last)} fmt="when" />
          <span :if={@counts.deleted > 0}> · {@counts.deleted} deleted from disk</span>
        <% true -> %>
          nothing saved yet
      <% end %>
    </span>
    <button
      class="link-button"
      phx-click="refresh_archive"
      disabled={@progress && @progress.running}
    >
      Refresh
    </button>
    """
  end

  attr :a, :map, required: true
  attr :live?, :boolean, default: false
  attr :local, :string, default: nil

  # A saved session, as small as a live card, with the numbers worth a glance.
  defp archive_card(assigns) do
    ~H"""
    <button
      class="session-card archive-card"
      phx-click="open_session"
      phx-value-machine={@a.machine}
      phx-value-id={@a.session_id}
    >
      <div class="row">
        <.tool_icon tool={@a[:tool]} />
        <span class="sc-name">{@a.title || short_id(@a)}</span>
        <span class="grow"></span>
        <span class={["badge", archive_badge_class(@a, @live?)]}>{archive_badge(@a, @live?)}</span>
      </div>
      <div class="sc-meta">
        <span class="sc-id">{short_id(@a)}</span>
        <span :if={@local && @a.machine != @local} class="acct">{@a.machine}</span>
        <span :if={@a.account} class="acct">{@a.account}</span>
        <span :if={@a.cwd} class="sc-folder">{Path.basename(@a.cwd)}</span>
      </div>
      <div class="sc-task">{@a.last_prompt || @a.first_prompt}</div>
      <div class="ctx-row">
        <span>
          {thousands(@a.requests)} requests · {thousands(@a.tool_calls)} tool calls<span :if={
            @a.subagents > 0
          }> · {@a.subagents} {if @a.subagents == 1, do: "subagent", else: "subagents"}</span>
        </span>
        <span :if={@a.ended_at}><.ago at={DateTime.from_unix!(@a.ended_at)} fmt="when" /></span>
      </div>
      <div class="sc-stats">
        <b :if={@a[:tool] == "codex"}>{short_tokens(saved_tokens(@a))} tokens</b>
        <b :if={@a[:tool] != "codex"}>{money(@a.cost)}</b>
        <span :if={@a.model}>{model_label(@a.model)}</span>
        <span class="plus">+{@a.lines_added}</span>
        <span class="minus">−{@a.lines_removed}</span>
        <span :if={korium_used?(@a)} class="kor">
          Korium {@a.korium_search_hits}/{@a.korium_searches} found · {@a.korium_saves -
            @a.korium_save_errors}/{@a.korium_saves} saved
        </span>
      </div>
    </button>
    """
  end

  defp archive_badge(_a, true), do: "Live"
  defp archive_badge(%{deleted_at: d}, _) when not is_nil(d), do: "Deleted"
  defp archive_badge(_, _), do: "Saved"

  defp archive_badge_class(_a, true), do: "badge-working"
  defp archive_badge_class(%{deleted_at: d}, _) when not is_nil(d), do: "badge-deleted"
  defp archive_badge_class(_, _), do: "badge-idle"

  defp korium_used?(a),
    do: a.korium_searches + a.korium_saves + a.code_searches + a.korium_index + a.korium_other > 0

  # A saved session's id as shown. A Codex id starts with the time, so its
  # end tells sessions apart.
  defp short_id(%{session_id: nil}), do: ""

  defp short_id(%{tool: "codex", session_id: id}),
    do: Wallboard.Archive.CodexTranscript.short_id(id)

  defp short_id(%{session_id: id}), do: String.slice(id, 0, 8)

  defp model_label(nil), do: nil

  defp model_label(model) do
    case Wallboard.Sources.Usage.price_for(model, Settings.get().usage.prices) do
      %{label: label} -> label
      _ -> model
    end
  end

  defp thousands(nil), do: "0"

  defp thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp thousands(n), do: n |> round() |> thousands()

  attr :s, :map, required: true
  attr :d, :map, default: nil
  attr :machine, :any, default: nil

  # One session. The first block comes from `claude agents`; the details
  # (context, cost, model, lines changed, subagents) from its transcript.
  defp session_card(assigns) do
    ~H"""
    <div
      class={[
        "session-card",
        @s.status == :needs && "needs",
        @s[:stale] && "stale",
        @machine && "tappable"
      ]}
      phx-click={@machine && @s.session_id && "open_session"}
      phx-value-machine={@machine}
      phx-value-id={@s.session_id}
    >
      <div class="row">
        <.tool_icon tool={@s[:tool]} />
        <span class="sc-name">{@s.name}</span>
        <span class="grow"></span>
        <span class={["badge", "badge-#{@s.status}"]}>{badge(@s.status)}</span>
      </div>
      <div class="sc-meta">
        <span class="sc-id">{@s.short_id}</span>
        <span :if={@s.account} class="acct">{@s.account}</span>
        <span :if={@s[:started_by]} class="acct">from {@s.started_by}</span>
        <span :if={@s[:repo]} class="sc-repo" title={@s.folder}>{@s.repo}</span>
        <span :if={!@s[:repo] && @s.folder} class="sc-folder">{@s.folder}</span>
      </div>
      <div class="sc-task">{if @s.status == :needs, do: @s.why, else: @s.task}</div>
      <%!-- Its machine's collector is not connected: this is how it stood
           when the hub last heard. --%>
      <div :if={@s[:stale]} class="stale-note small">
        stale: no word from {@s.machine} since <.ago at={@s.stale_since} fmt="when" />
      </div>

      <div :if={@d && @d.context_pct} class="ctx">
        <div class="bar thin">
          <div
            class={["bar-fill", ctx_tone(@d.context_pct)]}
            style={"width: #{min(@d.context_pct, 100)}%"}
          >
          </div>
        </div>
        <div class="ctx-row">
          <span>
            context {@d.context_pct}%<span :if={@d.subagents != []}> · {length(@d.subagents)} {if length(
                                                                                                    @d.subagents
                                                                                                  ) ==
                                                                                                    1,
                                                                                                  do:
                                                                                                    "subagent",
                                                                                                  else:
                                                                                                    "subagents"}</span>
          </span>
          <span>
            <%= case @s.status do %>
              <% :needs -> %>
                waiting <.ago at={@s.since} fmt="for" />
              <% :working -> %>
                working <.ago at={@s.since} fmt="for" />
              <% :idle -> %>
                updated <.ago at={@s.updated_at} />
            <% end %>
          </span>
        </div>
      </div>
      <div :if={!(@d && @d.context_pct)} class="sc-age">
        <%= case @s.status do %>
          <% :needs -> %>
            waiting <.ago at={@s.since} fmt="for" />
          <% :working -> %>
            working <.ago at={@s.since} fmt="for" /> · updated <.ago at={@s.updated_at} />
          <% :idle -> %>
            updated <.ago at={@s.updated_at} />
        <% end %>
      </div>

      <%!-- Codex runs on a plan with no per-token price: its tokens, and how
           much of the plan's limit is used, stand in for the cost. --%>
      <div :if={@d && @s[:tool] == :codex} class="sc-stats">
        <b>{short_tokens(@d.tokens)} tokens</b>
        <span :if={@d.plan_used}>plan {round(@d.plan_used)}%</span>
        <span :if={@d.model_label}>{@d.model_label}{if @d.effort, do: " · #{@d.effort}"}</span>
        <span class="plus">+{@d.added}</span>
        <span class="minus">−{@d.removed}</span>
      </div>
      <div :if={@d && @s[:tool] != :codex} class="sc-stats">
        <b>{money(@d.cost)}</b>
        <span :if={@d.model_label}>{@d.model_label}{if @d.effort, do: " · #{@d.effort}"}</span>
        <span class="plus">+{@d.added}</span>
        <span class="minus">−{@d.removed}</span>
      </div>
    </div>
    """
  end

  attr :tool, :any, default: nil
  attr :class, :string, default: "tool-icon"

  # Which tool ran a session: the Claude or the Codex app icon. Codex has a
  # dark tile and a white one; each theme uses the one that stands out from
  # its cards.
  defp tool_icon(%{tool: tool} = assigns) when tool in [:codex, "codex"] do
    ~H"""
    <span class={@class} title="Codex">
      <img
        class="for-light"
        src={"/images/codex-dark.png?v=" <> WallboardWeb.Layouts.asset_version()}
        alt="Codex"
      />
      <img
        class="for-dark"
        src={"/images/codex-light.png?v=" <> WallboardWeb.Layouts.asset_version()}
        alt=""
      />
    </span>
    """
  end

  defp tool_icon(assigns) do
    ~H"""
    <span class={@class} title="Claude"><img
      src={"/images/claude.png?v=" <> WallboardWeb.Layouts.asset_version()}
      alt="Claude"
    /></span>
    """
  end

  defp saved_tokens(a),
    do:
      (a.input_tokens || 0) + (a.output_tokens || 0) + (a.cache_read_tokens || 0) +
        (a.cache_write_tokens || 0)

  defp short_tokens(nil), do: "0"

  defp short_tokens(n) when n >= 1_000_000_000,
    do: :erlang.float_to_binary(n / 1_000_000_000, decimals: 1) <> "B"

  defp short_tokens(n) when n >= 1_000_000,
    do: :erlang.float_to_binary(n / 1_000_000, decimals: 1) <> "M"

  defp short_tokens(n) when n >= 1_000, do: "#{round(n / 1_000)}K"
  defp short_tokens(n), do: "#{n}"

  defp ctx_tone(pct) when pct >= 80, do: "bad"
  defp ctx_tone(pct) when pct >= 60, do: "warn"
  defp ctx_tone(_), do: nil

  defp money(nil), do: "$0.00"
  defp money(n) when n >= 1000, do: "$" <> thousands(round(n))
  defp money(n), do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)

  # ---------------------------------------------------------------------------
  # One saved session, over the whole board

  attr :s, :map, required: true
  attr :settings, :map, required: true

  defp session_detail(%{s: %{missing: true}} = assigns) do
    ~H"""
    <div class="detail-scrim" phx-click="close_session">
      <div class="detail detail-small" phx-click="noop">
        <div class="row">
          <h2 class="detail-title">Not saved yet</h2>
          <span class="grow"></span>
          <button class="close" phx-click="close_session" aria-label="Close">×</button>
        </div>
        <p class="detail-note">
          A session is saved once it has been quiet for {div(@settings.archive.settle_seconds, 60)} minutes, the first time it goes idle.
        </p>
      </div>
    </div>
    """
  end

  defp session_detail(assigns) do
    s = assigns.s
    d = s.detail || %{}

    assigns =
      assign(assigns,
        d: d,
        waited: waited_seconds(s.events),
        hit_pct:
          pct(s.cache_read_tokens, s.input_tokens + s.cache_read_tokens + s.cache_write_tokens),
        ctx_pct:
          s.context_window && s.context_window > 0 && pct(s.peak_context, s.context_window),
        tools:
          (d["tools"] || %{})
          |> Enum.map(fn {name, c} -> {tool_label(name), c["calls"] || 0, c["errors"] || 0} end)
          |> Enum.sort_by(fn {_, calls, _} -> -calls end),
        failures: d["korium_save_failures"] || %{}
      )

    ~H"""
    <div class="detail-scrim" phx-click="close_session">
      <div class="detail" phx-click="noop">
        <div class="row">
          <.tool_icon tool={@s[:tool]} />
          <h2 class="detail-title">{@s.title || short_id(@s)}</h2>
          <span class={["badge", if(@s.deleted_at, do: "badge-deleted", else: "badge-idle")]}>
            {if @s.deleted_at, do: "Deleted from disk", else: "Saved"}
          </span>
          <span class="grow"></span>
          <button class="close" phx-click="close_session" aria-label="Close">×</button>
        </div>
        <div class="detail-meta">
          <span :if={@s.account} class="acct">{@s.account}</span>
          <span :if={@s.cwd}>{@s.cwd}</span>
          <span :if={@s.git_branch}>branch {@s.git_branch}</span>
          <span>{@s.machine}</span>
          <span>{short_id(@s)}</span>
          <span :if={@s.version}>Claude Code {@s.version}</span>
        </div>
        <div class="detail-meta">
          <span :if={@s.started_at}>
            <.ago at={DateTime.from_unix!(@s.started_at)} fmt="when" /> to
            <.ago at={DateTime.from_unix!(@s.ended_at)} fmt="when" />
            ({duration(@s.ended_at - @s.started_at)})
          </span>
          <span :if={@waited > 0}>waited on you {duration(@waited)}</span>
          <span>saved <.ago at={DateTime.from_unix!(@s.captured_at)} fmt="when" /></span>
        </div>

        <div class="detail-body">
          <div class="stat-grid">
            <.stat
              label="Cost"
              value={money(@s.cost)}
              note={@s.subagent_cost > 0 && "#{money(@s.subagent_cost)} in subagents"}
            />
            <.stat label="Requests" value={thousands(@s.requests)} note={model_label(@s.model)} />
            <.stat
              label="Prompts"
              value={thousands(@s.prompts)}
              note={
                @s.turns > 0 &&
                  "#{thousands(@s.turns)} turns, #{duration(div(@s.turn_ms, @s.turns * 1000))} each"
              }
            />
            <.stat
              label="Tool calls"
              value={thousands(@s.tool_calls)}
              note={"#{thousands(@s.tool_errors)} failed"}
            />
            <.stat
              label="Lines"
              value={"+#{thousands(@s.lines_added)} −#{thousands(@s.lines_removed)}"}
              note={"#{@s.files_touched} files"}
            />
            <.stat label="Subagents" value={thousands(@s.subagents)} />
            <.stat label="Input" value={tokens(@s.input_tokens)} note="tokens" />
            <.stat label="Output" value={tokens(@s.output_tokens)} note="tokens" />
            <.stat
              label="Cache read"
              value={tokens(@s.cache_read_tokens)}
              note={@hit_pct && "#{@hit_pct}% of prompt"}
            />
            <.stat label="Cache write" value={tokens(@s.cache_write_tokens)} note="tokens" />
            <.stat
              label="Peak context"
              value={tokens(@s.peak_context)}
              note={@ctx_pct && "#{@ctx_pct}% of window"}
            />
            <.stat label="Compactions" value={thousands(@s.compactions)} />
            <.stat label="Time on model" value={@s.api_ms && duration(div(@s.api_ms, 1000))} />
            <.stat label="Time in tools" value={@s.tool_ms && duration(div(@s.tool_ms, 1000))} />
            <.stat
              label="API errors"
              value={thousands(@s.api_errors)}
              note={"#{thousands(@s.retries)} retries"}
            />
            <.stat label="Cut off" value={thousands(@s.aborted)} note="replies" />
            <.stat label="Denied" value={thousands(@s.denials)} note="by permission rules" />
            <.stat label="Pull requests" value={length(@d["prs"] || [])} />
            <.stat
              :if={@s[:ci]}
              label="CI minutes"
              value={thousands(@s.ci.paid)}
              note={ci_note(@s.ci)}
              wrap
            />
          </div>

          <div class="detail-cols">
            <div class="detail-col">
              <%= if korium_used?(@s) or @settings.korium.enabled do %>
                <h3 class="kicker">Korium</h3>
                <table class="dtable">
                  <tr>
                    <th></th>
                    <th>Calls</th>
                    <th>Found</th>
                    <th>Empty</th>
                  </tr>
                  <tr>
                    <td>Memory searches</td>
                    <td>{@s.korium_searches}</td>
                    <td>{@s.korium_search_hits}</td>
                    <td>{@s.korium_searches - @s.korium_search_hits}</td>
                  </tr>
                  <tr>
                    <td>Code searches</td>
                    <td>{@s.code_searches}</td>
                    <td>{@s.code_search_hits}</td>
                    <td>{@s.code_searches - @s.code_search_hits}</td>
                  </tr>
                </table>
                <table class="dtable">
                  <tr>
                    <th></th>
                    <th>Calls</th>
                    <th>Worked</th>
                    <th>Failed</th>
                  </tr>
                  <tr>
                    <td>Saves to memory</td>
                    <td>{@s.korium_saves}</td>
                    <td>{@s.korium_saves - @s.korium_save_errors}</td>
                    <td>{@s.korium_save_errors}</td>
                  </tr>
                </table>
                <p :if={@failures != %{}} class="detail-note">
                  Failed saves: {failure_words(@failures)}
                </p>
                <p class="detail-note">
                  Indexing runs: {@s.korium_index} · other Korium calls: {@s.korium_other}
                </p>
              <% end %>

              <h3 :if={(@d["models"] || %{}) != %{}} class="kicker gap-top">Models</h3>
              <table :if={(@d["models"] || %{}) != %{}} class="dtable">
                <tr>
                  <th></th>
                  <th>Requests</th>
                  <th>Cost</th>
                </tr>
                <tr :for={{m, v} <- Enum.sort_by(@d["models"], fn {_, v} -> -v["requests"] end)}>
                  <td>{model_label(m)}</td>
                  <td>{thousands(v["requests"])}</td>
                  <td>{money(v["cost"])}</td>
                </tr>
              </table>

              <h3 :if={@s.events != []} class="kicker gap-top">Status history</h3>
              <table :if={@s.events != []} class="dtable">
                <tr :for={e <- Enum.take(@s.events, -12)}>
                  <td><.ago at={DateTime.from_unix!(e.at)} fmt="when" /></td>
                  <td>{status_word(e.status)}</td>
                </tr>
              </table>
            </div>

            <div class="detail-col">
              <h3 class="kicker">Tools</h3>
              <table class="dtable">
                <tr>
                  <th></th>
                  <th>Calls</th>
                  <th>Failed</th>
                </tr>
                <tr :for={{name, calls, errors} <- Enum.take(@tools, 16)}>
                  <td>{name}</td>
                  <td>{thousands(calls)}</td>
                  <td class={errors > 0 && "bad-ink"}>{errors}</td>
                </tr>
              </table>
              <p :if={length(@tools) > 16} class="detail-note">
                and {length(@tools) - 16} more tools
              </p>
            </div>

            <div class="detail-col">
              <h3 :if={(@d["subagents"] || []) != []} class="kicker">Subagents</h3>
              <table :if={(@d["subagents"] || []) != []} class="dtable">
                <tr>
                  <th></th>
                  <th>Requests</th>
                  <th>Cost</th>
                  <th>Time</th>
                </tr>
                <tr :for={a <- Enum.take(@d["subagents"], 12)}>
                  <td>{a["type"] || a["description"] || "subagent"}</td>
                  <td>{thousands(a["requests"])}</td>
                  <td>{money(a["cost"])}</td>
                  <td>{a["seconds"] && duration(a["seconds"])}</td>
                </tr>
              </table>

              <h3 :if={(@d["prs"] || []) != []} class="kicker gap-top">Pull requests</h3>
              <div :for={pr <- @d["prs"] || []} class="detail-note">
                {pr["repo"]} #{pr["number"]}{pr_ci(@s, pr)}
              </div>

              <h3 :if={@s.first_prompt} class="kicker gap-top">First prompt</h3>
              <p :if={@s.first_prompt} class="detail-prompt">{@s.first_prompt}</p>
              <h3
                :if={@s.last_prompt && @s.last_prompt != @s.first_prompt}
                class="kicker gap-top"
              >
                Last prompt
              </h3>
              <p :if={@s.last_prompt && @s.last_prompt != @s.first_prompt} class="detail-prompt">
                {@s.last_prompt}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # The CI minutes of a saved session and of each pull request it opened,
  # read once when its details open.
  defp with_ci(s) do
    prs =
      for %{"repo" => repo, "number" => n} <- (s.detail || %{})["prs"] || [],
          is_binary(repo) and is_integer(n),
          into: %{},
          do: {{repo, n}, CiMinutes.for_pr(repo, n)}

    Map.merge(s, %{ci: CiMinutes.for_session(s), pr_ci: prs})
  end

  @doc """
  The note under a session's CI minutes: its runs, and the minutes that
  use up no plan.
  """
  def ci_note(%{runs: 0}), do: "no runs"

  def ci_note(ci) do
    [
      "#{thousands(ci.runs)} #{if ci.runs == 1, do: "run", else: "runs"}" <>
        if(ci.failed > 0, do: ", #{thousands(ci.failed)} failed", else: ""),
      ci.free > 0 && "#{thousands(ci.free)} free on a public repository",
      ci.own > 0 && "#{thousands(ci.own)} on your own machines"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # " · 22 CI min" after a pull request with saved runs; a public
  # repository's are free.
  defp pr_ci(s, pr) do
    case s[:pr_ci] && s.pr_ci[{pr["repo"], pr["number"]}] do
      %{runs: runs, free: free} when runs > 0 and free > 0 ->
        " · #{thousands(free)} CI min, free on a public repository"

      %{runs: runs, paid: paid} when runs > 0 ->
        " · #{thousands(paid)} CI min"

      _ ->
        ""
    end
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :any, default: nil
  # A note too long for one line wraps instead of being cut off.
  attr :wrap, :boolean, default: false

  defp stat(assigns) do
    ~H"""
    <div class="stat">
      <span class="kicker">{@label}</span>
      <span class="stat-value">{@value || "-"}</span>
      <span :if={@note} class={["stat-note", @wrap && "stat-note-wrap"]}>{@note}</span>
    </div>
    """
  end

  @doc "Seconds spent needing you, from a saved status history."
  def waited_seconds(events) do
    events
    |> Enum.chunk_every(2, 1)
    |> Enum.map(fn
      [%{status: "needs", at: a}, %{at: b}] -> b - a
      _ -> 0
    end)
    |> Enum.sum()
  end

  defp status_word("needs"), do: "needed you"
  defp status_word("working"), do: "working"
  defp status_word("idle"), do: "idle"
  defp status_word("gone"), do: "closed"
  defp status_word(other), do: other

  defp failure_words(failures) do
    words = %{
      "blocked" => "blocked by a hook",
      "invalid" => "bad input",
      "refused" => "refused by Korium"
    }

    failures
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.map_join(", ", fn {k, n} -> "#{n} #{words[k] || k}" end)
  end

  @doc ~s(A tool's name as a person says it: "mcp__claude_ai_korium__agent_search" is "korium: agent_search".)
  def tool_label("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [server, tool] -> String.replace_prefix(server, "claude_ai_", "") <> ": " <> tool
      _ -> rest
    end
  end

  def tool_label(name), do: name

  defp pct(_n, 0), do: nil
  defp pct(nil, _), do: nil
  defp pct(n, total), do: round(n * 100 / total)

  defp tokens(nil), do: "0"

  defp tokens(n) when n >= 1_000_000,
    do: :erlang.float_to_binary(n / 1_000_000, decimals: 1) <> "M"

  defp tokens(n) when n >= 10_000, do: "#{round(n / 1000)}K"
  defp tokens(n), do: thousands(n)

  defp duration(nil), do: nil
  defp duration(secs) when secs < 60, do: "#{secs}s"
  defp duration(secs) when secs < 3600, do: "#{div(secs, 60)}m #{rem(secs, 60)}s"

  defp duration(secs) when secs < 172_800,
    do: "#{div(secs, 3600)}h #{div(rem(secs, 3600), 60)}m"

  defp duration(secs), do: "#{div(secs, 86_400)}d #{div(rem(secs, 86_400), 3600)}h"

  # ---------------------------------------------------------------------------
  # Token trend

  attr :usage, :map, required: true
  attr :meta, :map, required: true

  defp token_trend(assigns) do
    ~H"""
    <section class="trend" aria-label="Token trend">
      <div class="heading-row">
        <h2 class="kicker">Token trend</h2>
        <.freshness meta={@meta} />
      </div>
      <%= if @usage && @usage.trend.rows != [] do %>
        <div class="trend-table">
          <div class="tr head">
            <span>Metric</span><span>Last 7 days</span><span>Previous 7</span><span>Change</span><span>Last 14 days</span>
          </div>
          <div :for={r <- @usage.trend.rows} class="tr">
            <span class="t-metric">{metric_name(r.metric)}</span>
            <span class="t-now">{metric_value(r.metric, r.current)}</span>
            <span class="t-prev">{metric_value(r.metric, r.previous)}</span>
            <span class={["t-change", change_tone(r.metric, r.change)]}>{change_words(
              r.metric,
              r.change
            )}</span>
            <span class="spark">
              <span
                :for={{v, h} <- spark(r.daily)}
                class="day"
                data-tip={"#{metric_name(r.metric)}: #{metric_value(r.metric, v)}"}
              >
                <span class={["sp", is_nil(v) && "empty"]} style={"height: #{h}%"}></span>
              </span>
            </span>
          </div>
        </div>
        <div class="trend-note">
          Days with activity only · at API list prices; a Claude plan is billed differently · cache hit over all {@usage.trend.active_days} active days {metric_value(
            :cache_hit,
            @usage.trend.lifetime_cache_hit
          )}
        </div>
      <% else %>
        <div class="empty-note">{@meta.error || "Reading Claude transcripts…"}</div>
      <% end %>
    </section>
    """
  end

  defp metric_name(:cost_per_request), do: "$ per request"
  defp metric_name(:cache_hit), do: "Cache hit rate"
  defp metric_name(:mean_context), do: "Mean context"
  defp metric_name(:spend_per_day), do: "Spend per day"
  defp metric_name(:requests_per_day), do: "Requests per day"

  defp metric_value(_, nil), do: "–"
  defp metric_value(:cost_per_request, v), do: "$" <> :erlang.float_to_binary(v / 1, decimals: 3)
  defp metric_value(:cache_hit, v), do: :erlang.float_to_binary(v / 1, decimals: 1) <> "%"
  defp metric_value(:mean_context, v), do: "#{round(v / 1000)}K"
  defp metric_value(:spend_per_day, v), do: "$" <> thousands(round(v))
  defp metric_value(:requests_per_day, v), do: thousands(round(v))

  defp change_words(_, nil), do: "–"

  defp change_words(metric, c) do
    arrow = if c < 0, do: "▼ ", else: "▲ "
    words = if abs(c) < 0.5, do: "no change", else: arrow <> "#{round(abs(c))}%"

    if metric in [:spend_per_day, :requests_per_day] and abs(c) >= 0.5,
      do: words <> " (volume)",
      else: words
  end

  # Green when the change is good, coral when it is bad, gray for volume.
  defp change_tone(_, nil), do: nil
  defp change_tone(m, _) when m in [:spend_per_day, :requests_per_day], do: "muted-ink"
  defp change_tone(_, c) when abs(c) < 0.5, do: "muted-ink"
  defp change_tone(:cache_hit, c), do: if(c > 0, do: "ok-ink", else: "bad-ink")
  defp change_tone(_, c), do: if(c < 0, do: "ok-ink", else: "bad-ink")

  defp spark(daily) do
    top = daily |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)

    Enum.map(daily, fn
      nil -> {nil, 6}
      v when top > 0 -> {v, max(round(v * 100 / top), 6)}
      v -> {v, 6}
    end)
  end

  defp badge(:needs), do: "Needs you"
  defp badge(:working), do: "Working"
  defp badge(:idle), do: "Idle"

  # ---------------------------------------------------------------------------
  # Git tab: one column per busy repository, the quiet rest in lines below

  attr :columns, :list, required: true
  attr :quiet, :list, required: true
  attr :now, :any, required: true
  attr :meta, :map, required: true

  defp git_tab(assigns) do
    assigns = assign(assigns, skipped: Settings.skipped_repos(Settings.get()))

    ~H"""
    <div class="git-tab">
      <div :if={@meta.error} class="stale-note small">GitHub: {@meta.error}</div>
      <div :if={@skipped != []} class="stale-note small">
        Left out of settings, not owner/name: {Enum.join(@skipped, ", ")}
      </div>
      <div
        class="git-cols"
        style={"grid-template-columns: repeat(#{max(length(@columns), 1)}, minmax(0, 1fr))"}
      >
        <.git_column :for={r <- @columns} r={r} now={@now} />
      </div>
      <%= if @quiet != [] do %>
        <div class="heading-row quiet-head">
          <h2 class="kicker">Quiet repos · {length(@quiet)}</h2>
          <span class="counts muted-ink">
            {if Enum.any?(@quiet, & &1.hot?),
              do: "more are busy than fit; the ones that ran last have the columns",
              else:
                "nothing running or failed in 6 hours; one moves up the moment it runs or goes red"}
          </span>
        </div>
        <div class="quiet-list">
          <.quiet_line :for={r <- @quiet} r={r} />
        </div>
      <% end %>
    </div>
    """
  end

  attr :r, :map, required: true
  attr :now, :any, required: true

  # One repository: its name and main, what runs now, what finished, and
  # the last 6 hours. Tapping the name opens its details.
  @doc false
  def git_column(assigns) do
    ~H"""
    <section class="git-col" aria-label={@r.repo}>
      <button
        class={["repo-head", main_red?(@r) && "red"]}
        phx-click="open_repo"
        phx-value-repo={@r.repo}
      >
        <span class="repo-name">
          <span class={["dot10", main_tone(@r)]}></span>{@r.name}
        </span>
        <span :if={@r.s} class="repo-stats">
          <span>Main <b>{main_word(@r)}</b>
          <.ago :if={@r.s.main} at={@r.s.main.updated_at} fmt="clock" /></span>
          <span>Queue <b>{queue_word(@r.s.queue)}</b></span>
          <span>Failed <b>{length(@r.s.failures)}</b></span>
        </span>
        <span :if={runners(@r) != []} class="repo-stats">
          <span>Runners <b>{Runners.count_line(runners(@r))}</b></span>
        </span>
        <span :if={@r.error} class="stale-note small">stale: {@r.error}</span>
      </button>
      <%= if @r.s do %>
        <h3 class="kicker">Running now</h3>
        <div :if={@r.s.running == []} class="empty-box small">Nothing running</div>
        <.run_card :for={x <- Enum.take(@r.s.running, 2)} r={x} repo={@r.repo} />
        <h3 class="kicker">Recent</h3>
        <.recent_list runs={@r.s.recent} repo={@r.repo} />
        <h3 class="kicker">Runs · last 6 hours</h3>
        <.timeline lanes={@r.s.lanes} more={@r.s.lanes_more} now={@now} />
      <% else %>
        <div class="empty-box small">
          {if @r.error, do: "Could not read it yet", else: "Loading from GitHub…"}
        </div>
      <% end %>
    </section>
    """
  end

  attr :r, :map, required: true

  # A repository with nothing going on: one line, which opens its details.
  defp quiet_line(assigns) do
    last = assigns.r.s && List.first(assigns.r.s.recent)
    assigns = assign(assigns, last: last)

    ~H"""
    <button class="quiet-line" phx-click="open_repo" phx-value-repo={@r.repo}>
      <b class="ql-name">{@r.name}</b>
      <span class="ql-main">
        <span class={["dot8", main_tone(@r)]}></span> Main {String.downcase(main_word(@r))}
        <.ago :if={@r.s && @r.s.main} at={@r.s.main.updated_at} fmt="clock" />
      </span>
      <span>{if @r.s && @r.s.running != [],
        do: "#{length(@r.s.running)} running",
        else: "Nothing running"}</span>
      <span class="ql-last">
        <%!-- A repository that cannot be read says so before anything old. --%>
        <%= cond do %>
          <% @r.error -> %>
            <span class="stale-note">stale: {@r.error}</span>
          <% @last -> %>
            Last: {@last.label} · {@last.what}
            <span class={result_class(@last.conclusion)}>{result_icon(@last.conclusion)}</span>
          <% true -> %>
            No runs in the last day
        <% end %>
      </span>
      <span class="ql-when"><.ago :if={@last && !@r.error} at={@last.updated_at} fmt="when" /></span>
    </button>
    """
  end

  defp main_red?(%{s: %{main: %{conclusion: "failure"}}}), do: true
  defp main_red?(_), do: false

  defp main_tone(%{s: %{main: %{conclusion: "success"}}}), do: "ok"
  defp main_tone(%{s: %{main: %{conclusion: "failure"}}}), do: "bad"
  defp main_tone(_), do: "muted"

  defp main_word(%{s: %{main: %{conclusion: "success"}}}), do: "Green"
  defp main_word(%{s: %{main: %{conclusion: "failure"}}}), do: "Red"
  defp main_word(_), do: "Unknown"

  defp queue_word([]), do: "0"
  defp queue_word(queue), do: "#{length(queue)} waiting"

  # A repository's own (self-hosted) runners, none when it has no summary.
  defp runners(%{s: %{runners: list}}), do: list
  defp runners(_), do: []

  # " · on kyroco-air-1" for a run your own machines ran; nothing for one
  # GitHub ran.
  defp on_own(%{own: [_ | _] = names}), do: " · on " <> Enum.join(names, ", ")
  defp on_own(_), do: nil

  # The runners that ran its jobs but that nothing reports, nil for none.
  defp unreported(%{s: %{runners_unreported: u}}), do: u
  defp unreported(_), do: nil

  attr :runners, :list, required: true
  attr :unreported, :map, default: nil

  # A repository's own runners, each with its state and what it runs, and
  # one line for those that ran its jobs but whose state nothing reports.
  # Nothing when it has none.
  @doc false
  def runners_table(assigns) do
    ~H"""
    <%= if @runners != [] or @unreported do %>
      <h3 class="kicker gap-top">Your runners</h3>
      <table class="dtable runners">
        <tr :for={x <- @runners}>
          <td>{x.name}</td>
          <td class={"runner-#{x.state}"}>{Runners.word(x.state)}</td>
          <td>{runner_note(x)}</td>
        </tr>
        <tr :if={@unreported}>
          <td>{if @runners == [], do: "", else: "#{@unreported.count} more"}</td>
          <td class="runner-unknown">{Runners.word(:unknown)}</td>
          <td>
            {@unreported.count} {if @unreported.count == 1, do: "runner", else: "runners"} ran this repository's jobs in the last day. {@unreported.why}.
          </td>
        </tr>
      </table>
    <% end %>
    """
  end

  defp runner_note(%{state: :busy, job: job}) when is_binary(job), do: job
  defp runner_note(%{from: :github}), do: "from GitHub"
  defp runner_note(%{from: :collector}), do: "from the collector on that machine"
  defp runner_note(_), do: nil

  attr :r, :map, required: true
  attr :repo, :string, required: true

  # A run going now. Tapping it opens its details.
  defp run_card(assigns) do
    ~H"""
    <button
      type="button"
      class="run-card"
      phx-click="open_run"
      phx-value-repo={@repo}
      phx-value-id={@r.id}
    >
      <span class="row baseline">
        <svg
          width="16"
          height="16"
          viewBox="0 0 16 16"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          aria-hidden="true"
          class="spin"
        >
          <circle cx="8" cy="8" r="6" stroke-dasharray="26 12"></circle>
        </svg>
        <span class="rc-name">{@r.name}</span>
        <span class="rc-what">{@r.what}</span>
        <span class="rc-elapsed"><.ago at={@r.started_at} fmt="for" /></span>
      </span>
      <span class="bar">
        <span class="bar-fill" style={"width: #{@r.progress}%"}></span>
      </span>
      <span class="rc-step">{@r.step}<span :if={on_own(@r)} class="own-tag">{on_own(@r)}</span></span>
    </button>
    """
  end

  attr :runs, :list, required: true
  attr :repo, :string, required: true

  # Finished runs, newest first; rows that do not fit whole are hidden.
  # Tapping one opens its details.
  defp recent_list(assigns) do
    ~H"""
    <div :if={@runs == []} class="empty-box small">No finished runs in the last day</div>
    <div :if={@runs != []} class="list recent" data-clip>
      <%!-- data-keep: a row app.js hid stays hidden through an update. --%>
      <button
        :for={x <- @runs}
        type="button"
        class="recent-row"
        data-keep="style"
        phx-click="open_run"
        phx-value-repo={@repo}
        phx-value-id={x.id}
      >
        <span class={["icon", result_class(x.conclusion)]}>{result_icon(x.conclusion)}</span>
        <span class="rr-text">
          <span class="rr-name">{x.label}</span>
          <span class="rr-what">
            {x.what}<span :if={on_own(x)} class="own-tag">{on_own(x)}</span>
          </span>
        </span>
        <span class="rr-when">
          <span class="rr-time"><.ago at={x.updated_at} fmt="clock" /></span>
          <span class="rr-took">{took(x.took)}</span>
        </span>
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # One repository, over the whole board

  attr :r, :map, required: true
  attr :facts, :map, default: nil
  attr :meta, :map, required: true

  defp repo_detail(assigns) do
    assigns =
      assign(assigns,
        workflows: if(assigns.facts, do: GitHub.by_workflow(assigns.facts), else: [])
      )

    ~H"""
    <div class="detail-scrim" phx-click="close_repo">
      <div class="detail" phx-click="noop">
        <div class="row">
          <span class={["dot12", main_tone(@r)]}></span>
          <h2 class="detail-title">{@r.repo}</h2>
          <span class="grow"></span>
          <button class="close" phx-click="close_repo" aria-label="Close">×</button>
        </div>
        <div class="detail-meta">
          <span>Main {String.downcase(main_word(@r))}</span>
          <span :if={@r.s && @r.s.main}>
            {if @r.s.main_from == :gate, do: "gate", else: "latest run"}
            <.ago at={@r.s.main.updated_at} fmt="when" />
          </span>
          <span :if={@r.s && @r.s.last_merge}>
            last merge #{@r.s.last_merge.pr} <.ago at={@r.s.last_merge.updated_at} fmt="when" />
          </span>
          <span>updated <.ago at={@meta.fetched_at} /></span>
          <span :if={@r.error} class="stale-note">stale: {@r.error}</span>
        </div>

        <div :if={!@r.s} class="empty-note">
          {if @r.error, do: @r.error, else: "Loading from GitHub…"}
        </div>
        <div :if={@r.s} class="detail-body">
          <div class="stat-grid">
            <.stat label="Main" value={main_word(@r)} />
            <.stat label="Merge queue" value={queue_word(@r.s.queue)} />
            <.stat label="Running" value={length(@r.s.running)} />
            <.stat label="Failed · 24h" value={length(@r.s.failures)} />
            <.stat label="Open pull requests" value={length(@r.s.prs)} />
            <.stat label="Workflows" value={length(@workflows)} note="that ran lately" />
          </div>

          <div class="detail-cols">
            <div class="detail-col">
              <h3 class="kicker">Running now</h3>
              <div :if={@r.s.running == []} class="empty-box small">Nothing running</div>
              <.run_card :for={x <- @r.s.running} r={x} repo={@r.repo} />

              <.runners_table runners={runners(@r)} unreported={unreported(@r)} />

              <h3 class="kicker gap-top">Merge queue</h3>
              <div :if={@r.s.queue == []} class="empty-box small">Empty</div>
              <table :if={@r.s.queue != []} class="dtable">
                <tr :for={q <- @r.s.queue}>
                  <td>#{q.pr} {q.title}</td>
                  <td>{q.state && String.downcase(q.state)}</td>
                  <td><.ago at={q.enqueued_at} /></td>
                </tr>
              </table>

              <h3 class="kicker gap-top">Failures · 24h</h3>
              <div :if={@r.s.failures == []} class="empty-box small">None</div>
              <table :if={@r.s.failures != []} class="dtable">
                <tr
                  :for={f <- @r.s.failures}
                  class="tap-row"
                  phx-click="open_run"
                  phx-value-repo={@r.repo}
                  phx-value-id={f.id}
                >
                  <td><button type="button" class="row-link">{f.name} · {GitHub.what(f)}</button></td>
                  <td><.ago at={f.updated_at} fmt="when" /></td>
                </tr>
              </table>

              <h3 class="kicker gap-top">Pull requests</h3>
              <div :if={@r.s.prs == []} class="empty-box small">None open</div>
              <table :if={@r.s.prs != []} class="dtable">
                <tr :for={p <- @r.s.prs}>
                  <td>#{p.number} {p.title}</td>
                  <td class={"gate-#{p.gate}"}>{gate_words(p.gate, p.draft)}</td>
                  <td><.ago at={p.updated_at} /></td>
                </tr>
              </table>
            </div>

            <div class="detail-col detail-wide">
              <h3 class="kicker">Every workflow</h3>
              <div class="workflow-grid">
                <div :for={{name, runs} <- @workflows} class="workflow">
                  <span class="wf-name">{name}</span>
                  <table class="dtable">
                    <tr
                      :for={x <- Enum.take(runs, 5)}
                      class="tap-row"
                      phx-click="open_run"
                      phx-value-repo={@r.repo}
                      phx-value-id={x.id}
                    >
                      <td>
                        <button type="button" class="row-link">
                          <span class={result_class(x.conclusion)}>{run_icon(x)}</span> {x.what}
                        </button>
                      </td>
                      <td><.ago at={x.updated_at || x.started_at} fmt="when" /></td>
                      <td>{took(x.took)}</td>
                    </tr>
                  </table>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp run_icon(%{status: :completed, conclusion: c}), do: result_icon(c)
  defp run_icon(_), do: "●"

  # ---------------------------------------------------------------------------
  # One run, over the whole board or over its repository's details

  attr :v, :map, required: true

  defp run_detail(assigns) do
    run = assigns.v.run

    assigns =
      assign(assigns,
        run: run,
        jobs: if(is_list(assigns.v.jobs), do: sort_jobs(assigns.v.jobs)),
        rerun_by: run[:started_by] && run[:actor] != run[:started_by] && run[:started_by]
      )

    ~H"""
    <div class="detail-scrim" phx-click="close_run">
      <div class="detail detail-run" phx-click="noop">
        <div class="row">
          <span class={["dot12", run_tone(@run)]}></span>
          <h2 class="detail-title">{@run.name}</h2>
          <span class={["badge", "badge-run-#{run_tone(@run)}"]}>{run_state(@run)}</span>
          <span class="grow"></span>
          <button class="close" phx-click="close_run" aria-label="Close">×</button>
        </div>
        <div class="detail-meta">
          <span>{@v.repo}</span>
          <span :if={@run.status == :completed && @run.took}>ran {took(@run.took)}</span>
          <span :if={@run.status == :in_progress && @run.started_at}>
            running for <.ago at={@run.started_at} fmt="for" />
          </span>
          <span :if={@run.status == :queued}>waiting for a runner</span>
          <span :if={@run.started_at}>started <.ago at={@run.started_at} fmt="when" /></span>
          <span :if={(@run[:attempt] || 1) > 1}>attempt {@run.attempt}</span>
        </div>
        <div class="detail-meta">
          <span :if={@run.branch}>branch {@run.branch}</span>
          <span :if={@run.sha} class="run-commit">
            <code>{@run.sha}</code> {@run[:commit] || @run.title}
          </span>
          <span>{event_words(@run)}</span>
          <span :if={@run[:actor]}>by {@run.actor}</span>
          <span :if={@rerun_by}>rerun by {@rerun_by}</span>
          <a
            :if={@run.url}
            href={@run.url}
            target="_blank"
            rel="noopener noreferrer"
            class="link-button"
          >
            Open on GitHub
          </a>
        </div>

        <div class="detail-body">
          <h3 class="kicker">Jobs{if @jobs, do: " · #{length(@jobs)}"}</h3>
          <%= case @v.jobs do %>
            <% :loading -> %>
              <div class="empty-box small">Loading jobs…</div>
            <% :waiting -> %>
              <div class="empty-box small">Waiting for a runner</div>
            <% :pending -> %>
              <div class="empty-box small">The jobs show at the next check</div>
            <% {:error, why} -> %>
              <div class="empty-box small">Could not read the jobs: {why}</div>
            <% _ -> %>
              <div :if={@jobs == []} class="empty-box small">No jobs</div>
              <div :if={@jobs != []} class="job-list">
                <.job_line :for={j <- @jobs} j={j} listed={@v[:listed] || []} />
              </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :j, :map, required: true
  attr :listed, :list, default: []

  # One job: its state, name, the step that failed, the runner (marked when
  # it is one of your own machines; see Wallboard.Runners) and how long.
  defp job_line(assigns) do
    assigns = assign(assigns, own?: Runners.kind(assigns.j, assigns.listed) == :own)

    ~H"""
    <div class="job-line">
      <span class={["job-icon", job_class(@j)]}>
        <svg
          :if={@j.status == "in_progress"}
          width="14"
          height="14"
          viewBox="0 0 16 16"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          aria-hidden="true"
          class="spin"
        >
          <circle cx="8" cy="8" r="6" stroke-dasharray="26 12"></circle>
        </svg>
        {if @j.status != "in_progress", do: job_icon(@j)}
      </span>
      <span class="job-text">
        <span class="job-name">{@j.name}</span>
        <span :if={@j.failed_step} class="job-failed">failed at: {@j.failed_step}</span>
        <span :if={@j.status == "in_progress" && @j[:current_step]} class="job-step">
          now: {@j.current_step}
        </span>
      </span>
      <span class="job-runner">
        {cond do
          @j.runner_name not in [nil, ""] -> "on " <> @j.runner_name
          @j.status in ["queued", "waiting", "pending"] -> "waiting for a runner"
          true -> ""
        end}<span :if={@own? and @j.runner_name not in [nil, ""]} class="own-tag"> · your machine</span>
      </span>
      <span class="job-time">
        <%= cond do %>
          <% @j.status == "in_progress" && @j.started_at -> %>
            <.ago at={DateTime.from_unix!(@j.started_at)} fmt="for" />
          <% @j.duration_s -> %>
            {took(@j.duration_s)}
          <% true -> %>
            {job_state(@j)}
        <% end %>
      </span>
    </div>
    """
  end

  # In the order they ran: the started ones by start, then the ones still
  # waiting by when they were made.
  defp sort_jobs(jobs),
    do:
      Enum.sort_by(
        jobs,
        &{is_nil(&1.started_at), &1.started_at || &1.created_at || 0, &1.name || ""}
      )

  defp run_tone(%{status: :completed, conclusion: "success"}), do: "ok"
  defp run_tone(%{status: :completed, conclusion: "failure"}), do: "bad"
  defp run_tone(%{status: :completed}), do: "muted"
  defp run_tone(_), do: "info"

  defp run_state(%{status: :queued}), do: "Waiting"
  defp run_state(%{status: :in_progress}), do: "Running"
  defp run_state(%{conclusion: c}), do: conclusion_word(c)

  defp job_state(%{status: "completed", conclusion: c}), do: conclusion_word(c)
  defp job_state(%{status: "in_progress"}), do: "Running"
  defp job_state(_), do: "Waiting"

  defp conclusion_word("success"), do: "Passed"
  defp conclusion_word("failure"), do: "Failed"
  defp conclusion_word("cancelled"), do: "Cancelled"
  defp conclusion_word("skipped"), do: "Skipped"
  defp conclusion_word("timed_out"), do: "Timed out"
  defp conclusion_word("action_required"), do: "Needs approval"
  defp conclusion_word(nil), do: "Finished"
  defp conclusion_word(c), do: c |> String.replace("_", " ") |> String.capitalize()

  defp job_icon(%{status: "completed", conclusion: c}), do: result_icon(c)
  defp job_icon(_), do: "○"

  defp job_class(%{status: "completed", conclusion: c}), do: result_class(c)
  defp job_class(%{status: "in_progress"}), do: "info-ink"
  defp job_class(_), do: "muted-ink"

  # What started a run, in plain words.
  defp event_words(%{event: "push"}), do: "push"

  defp event_words(%{event: "pull_request", pr: pr}) when is_integer(pr),
    do: "pull request ##{pr}"

  defp event_words(%{event: "pull_request"}), do: "pull request"
  defp event_words(%{event: "merge_group"}), do: "merge queue"
  defp event_words(%{event: "workflow_dispatch"}), do: "started by hand"
  defp event_words(%{event: "schedule"}), do: "on a schedule"
  defp event_words(%{event: "dynamic"}), do: "GitHub's own job"
  defp event_words(%{event: "workflow_run"}), do: "after another workflow"
  defp event_words(%{event: nil}), do: "started"
  defp event_words(%{event: e}), do: String.replace(e, "_", " ")

  defp gate_words(gate, draft) do
    words =
      case gate do
        :passed -> "gate passed"
        :failed -> "gate failed"
        :running -> "gate running"
        _ -> "no gate yet"
      end

    if draft, do: "draft · " <> words, else: words
  end

  defp result_icon("success"), do: "✓"
  defp result_icon("failure"), do: "✗"
  defp result_icon(_), do: "–"
  defp result_class("success"), do: "ok-ink"
  defp result_class("failure"), do: "bad-ink"
  defp result_class(_), do: "muted-ink"

  @doc false
  def took(nil), do: ""
  def took(s) when s < 60, do: "#{s}s"
  def took(s) when s < 3600, do: "#{div(s, 60)}m"
  def took(s), do: "#{div(s, 3600)}h #{rem(div(s, 60), 60)}m"

  # ---------------------------------------------------------------------------
  # 6-hour timeline

  attr :lanes, :list, required: true
  attr :more, :integer, default: 0
  attr :now, :any, required: true

  @window 6 * 3600

  # One row for each workflow that ran. Bars: teal passed, red failed, an
  # outline still running. Every other hour is marked, which fits a column
  # a quarter of the board wide. With no rows, nothing ran, and it says so.
  @doc false
  def timeline(%{lanes: []} = assigns) do
    ~H"""
    <div class="empty-box small">No runs in the last 6 hours</div>
    """
  end

  def timeline(assigns) do
    assigns = assign(assigns, hours: assigns.now |> hour_marks() |> every_other())

    ~H"""
    <div class="timeline" aria-label="Runs, last 6 hours">
      <div :for={lane <- @lanes} class="lane">
        <span class="lane-name" title={lane.label}>{lane.label}</span>
        <div class="lane-track">
          <span
            :for={b <- lane.bars}
            class={["lbar", b.kind]}
            style={bar_style(b)}
          ></span>
        </div>
      </div>
      <div class="lane axis">
        <span></span>
        <div class="axis-track">
          <.ago :for={{at, left} <- @hours} at={at} fmt="hour" class="tick" style={"left: #{left}%"} />
          <span class="tick now">now</span>
        </div>
      </div>
      <div :if={@more > 0} class="lane-more">
        +{@more} more {if @more == 1, do: "workflow", else: "workflows"} ran
      </div>
    </div>
    """
  end

  # Counted back from the last mark, so the one nearest now always shows.
  defp every_other(marks),
    do: marks |> Enum.reverse() |> Enum.take_every(2) |> Enum.reverse()

  defp pct(seconds), do: Float.round(seconds * 100 / @window, 3)

  # A run that began before the window shows only its part inside it, and
  # every bar is at least 90 seconds wide so a quick run is still visible.
  defp bar_style(%{start: start, length: length}) do
    left = max(start, 0)
    visible = min(length + min(start, 0), @window - left)
    "left: #{pct(left)}%; width: #{pct(max(visible, 90))}%"
  end

  # Whole hours inside the window, as {time, left %}. Hours line up with UTC
  # hours for US time zones, which is what the labels need.
  defp hour_marks(now) do
    start = DateTime.add(now, -@window, :second)
    first = %{start | minute: 0, second: 0, microsecond: {0, 0}} |> DateTime.add(3600, :second)

    Stream.iterate(first, &DateTime.add(&1, 3600, :second))
    |> Enum.take_while(&(DateTime.diff(now, &1, :second) > 45 * 60))
    |> Enum.map(&{&1, pct(DateTime.diff(&1, start, :second))})
  end

  # ---------------------------------------------------------------------------
  # Page 2: New Relic

  attr :nr, :map, required: true
  attr :meta, :map, required: true
  attr :now, :any, required: true
  attr :slots, :integer, required: true

  defp new_relic(assigns) do
    checks = (assigns.nr && assigns.nr.checks) || []
    {hero, rest} = split_hero(checks)
    empty = max(assigns.slots - length(rest), 0)
    assigns = assign(assigns, hero: hero, rest: rest, empty: empty)

    ~H"""
    <%= if @hero do %>
      <section class="hero" aria-label={@hero.name}>
        <div class="hero-top">
          <div class={["hero-icon", if(@hero.up, do: "up", else: "down")]}>
            <svg
              width="48"
              height="48"
              viewBox="0 0 48 48"
              fill="none"
              stroke="currentColor"
              stroke-width="3.5"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M4 26h9l5-12 8 22 6-14 4 4h8"></path>
            </svg>
          </div>
          <div class="hero-main">
            <div class="kicker">{@hero.name} <.freshness meta={@meta} /></div>
            <div class="row baseline">
              <span class={["hero-state", !@hero.up && "bad-ink"]}>{hero_state(@hero)}</span>
              <span class="hero-what">{@hero.monitor}<span :if={@hero.url}> · {@hero.url}</span></span>
            </div>
          </div>
          <div class="hero-stats">
            <div class="stat">
              <span class="kicker">Uptime · 24h</span>
              <span class="stat-value">{percent(@hero.uptime)}</span>
            </div>
            <div class="stat">
              <span class="kicker">Response · median</span>
              <span class="stat-value">{ms(@hero.median_ms)}</span>
            </div>
            <div class="stat">
              <span class="kicker">Last check</span>
              <span class="stat-value"><.ago at={@hero.last_at} fmt="clock" /></span>
            </div>
          </div>
        </div>

        <div class="strip-block">
          <div class="heading-row">
            <span class="kicker">Every check · last 24 hours</span>
            <span class="grow"></span>
            <span class="legend"><span class="sw okfill"></span>passed</span>
            <span class="legend"><span class="sw fail"></span>failed</span>
          </div>
          <div class="strip">
            <span :for={s <- @hero.slots} class={["cell", s.result]}></span>
          </div>
          <div class="strip-axis">
            <span><.ago at={DateTime.add(@now, -24 * 3600, :second)} fmt="hour" /> yesterday</span>
            <.ago at={DateTime.add(@now, -18 * 3600, :second)} fmt="hour" />
            <.ago at={DateTime.add(@now, -12 * 3600, :second)} fmt="hour" />
            <.ago at={DateTime.add(@now, -6 * 3600, :second)} fmt="hour" />
            <span>now</span>
          </div>
        </div>

        <div class="strip-block">
          <span class="kicker">Response time · last 24 hours</span>
          <div class="latency">
            <span
              :for={{s, h} <- latency(@hero.slots)}
              class={["lat", s.result == :fail && "fail"]}
              style={"height: #{h}%"}
            ></span>
          </div>
        </div>
      </section>
    <% else %>
      <section class="hero setup" aria-label="New Relic">
        <div class="kicker">New Relic <.freshness meta={@meta} /></div>
        <div class="setup-title">{setup_title(@meta.error)}</div>
        <div class="setup-body">{setup_body(@meta.error)}</div>
      </section>
    <% end %>

    <section class="more" aria-label="More checks">
      <h2 class="kicker">More checks · added in settings as they move to New Relic</h2>
      <div class="more-grid">
        <div :for={c <- @rest} class="check-card">
          <span class="cc-name">{c.name}</span>
          <span :if={c.kind == :nrql} class="cc-value">{format_value(c.value)}{c.unit}</span>
          <span :if={c.kind == :monitor} class={["cc-value", !c.up && "bad-ink"]}>{hero_state(c)} · {percent(
            c.uptime
          )}</span>
        </div>
        <div :for={_ <- List.duplicate(nil, @empty)} class="slot">
          <span class="slot-name">Next check</span>
          <span class="slot-note">Add it to new_relic.checks in settings.exs</span>
        </div>
      </div>
    </section>
    """
  end

  defp split_hero(checks) do
    case Enum.find_index(checks, &(&1.kind == :monitor)) do
      nil -> {nil, checks}
      i -> {Enum.at(checks, i), List.delete_at(checks, i)}
    end
  end

  defp hero_state(%{last_result: nil}), do: "No data"
  defp hero_state(%{up: true}), do: "Up"
  defp hero_state(_), do: "Down"

  defp setup_title(error) do
    if error && String.contains?(error, ["key", "1Password"]),
      do: "New Relic key not loaded",
      else: "New Relic is not set up yet"
  end

  defp setup_body(nil), do: "Waiting for the first check."

  defp setup_body(error) do
    error <>
      " In the VitalAIze app's Settings or with vitalaize setup, type the New Relic API key, or where it is in " <>
      "1Password (like \"op://Vault/Item/credential\"), and the account number. The checks go in new_relic.checks " <>
      "in settings.exs."
  end

  defp latency(slots) do
    top = slots |> Enum.map(& &1.avg_ms) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

    Enum.map(slots, fn s ->
      h = if top && s.avg_ms && top > 0, do: max(round(s.avg_ms * 100 / top), 4), else: 0
      {s, h}
    end)
  end

  defp percent(nil), do: "–"
  defp percent(n), do: :erlang.float_to_binary(n / 1, decimals: 1) <> "%"
  defp ms(nil), do: "–"
  defp ms(n), do: "#{round(n)} ms"
  defp format_value(nil), do: "–"
  defp format_value(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp format_value(n), do: to_string(n)
end
