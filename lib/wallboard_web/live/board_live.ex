defmodule WallboardWeb.BoardLive do
  @moduledoc """
  The board: page 1 (build heartbeat) and page 2 (New Relic), side by side.
  The browser rotates between them and handles swipes; the server only sends
  what changed.

  Times go to the browser as timestamps, and the browser writes them in the
  time zone from settings ("1:27 PM", "4m ago"), so the clock and the ages
  tick without the server sending anything.
  """
  use WallboardWeb, :live_view

  alias Wallboard.{Poller, Settings, Store}
  alias Wallboard.Archive.{Collector, Trends}
  alias Wallboard.Sources.{Builds, Claude, DevPower, GitHub}

  # How often the server redraws what depends on the time of day: the
  # 6-hour timeline and the "last 24 hours" counts.
  @tick_ms 30_000

  # The product's name, beside the brand at the top of page 1. It is fixed, not
  # a setting, so an old settings file can never show an old name.
  @product "VitalAIze"

  @impl true
  def mount(_params, _session, socket) do
    # A screen left open across an update reconnects on its own but keeps the
    # old app.css and app.js, so it gets a full reload to fetch the new ones.
    if connected?(socket) and
         get_connect_params(socket)["asset_version"] != WallboardWeb.Layouts.asset_version() do
      {:ok, redirect(socket, to: "/")}
    else
      mount_board(socket)
    end
  end

  defp mount_board(socket) do
    settings = Settings.get()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Poller.topic())
      :timer.send_interval(@tick_ms, :tick)
    end

    claude = Poller.snapshot(:claude)
    codex = Poller.snapshot(:codex)
    github = Poller.snapshot(:github)
    nr = Poller.snapshot(:new_relic)
    usage = Poller.snapshot(:usage)
    dev = Poller.snapshot(:dev_power)
    builds = Poller.snapshot(:builds)

    socket =
      socket
      |> assign(settings: settings, now: now(), product: @product)
      |> assign(claude: claude.facts, claude_meta: claude.meta)
      |> assign(codex: codex.facts)
      |> assign(github: github.facts, github_meta: github.meta)
      |> assign(nr: nr.facts, nr_meta: nr.meta)
      |> assign(usage: usage.facts, usage_meta: usage.meta)
      |> assign(dev: dev.facts, dev_meta: dev.meta, dev_on?: DevPower.enabled?(settings))
      |> assign(builds: builds.facts)
      |> assign(
        archive_on?: settings.archive.enabled,
        machine: if(settings.archive.enabled, do: Collector.machine(settings)),
        session_tab: :live,
        archive: [],
        archive_counts: nil,
        archive_progress: nil,
        selected: nil,
        back_ref: nil,
        trends: nil,
        trend_days: 14
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

  def handle_info({:source, :github, facts, meta}, socket),
    do:
      {:noreply,
       socket |> assign(github: facts, github_meta: meta, now: now()) |> derive_github()}

  def handle_info({:source, :new_relic, facts, meta}, socket),
    do: {:noreply, assign(socket, nr: facts, nr_meta: meta)}

  def handle_info({:source, :usage, facts, meta}, socket),
    do: {:noreply, assign(socket, usage: facts, usage_meta: meta)}

  def handle_info({:source, :dev_power, facts, meta}, socket),
    do: {:noreply, assign(socket, dev: facts, dev_meta: meta)}

  def handle_info({:source, :builds, facts, _meta}, socket),
    do: {:noreply, assign(socket, builds: facts)}

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

  def handle_info(:tick, socket),
    do: {:noreply, socket |> assign(now: now()) |> derive_sessions() |> derive_github()}

  # A collector saved a round: an open Archive or Trends tab shows it.
  def handle_info({:archive, _}, socket) do
    case socket.assigns.session_tab do
      :archive -> {:noreply, load_archive(socket)}
      :trends -> {:noreply, load_trends(socket)}
      _ -> {:noreply, socket}
    end
  end

  # Nobody touched the Archive tab for a while: back to the live sessions,
  # so a wall screen never hides a session that needs you.
  def handle_info({:back_to_live, ref}, %{assigns: %{back_ref: ref}} = socket),
    do: {:noreply, assign(socket, session_tab: :live, selected: nil, back_ref: nil)}

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
    selected = Store.get_session(m, id) || %{missing: true, session_id: id}
    {:noreply, socket |> assign(selected: selected) |> touched()}
  end

  def handle_event("open_session", _params, socket), do: {:noreply, socket}

  def handle_event("close_session", _params, socket),
    do: {:noreply, socket |> assign(selected: nil) |> touched()}

  def handle_event("refresh_archive", _params, %{assigns: %{archive_on?: true}} = socket) do
    Collector.refresh()

    {:noreply,
     socket |> assign(archive_progress: %{Collector.progress() | running: true}) |> touched()}
  end

  def handle_event(_, _params, socket), do: {:noreply, socket}

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
  defp touched(%{assigns: %{session_tab: :live, selected: nil}} = socket),
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
    sessions = Enum.map(claude, &Map.put(&1, :tool, :claude)) ++ codex
    long = settings.claude.long_running_minutes

    sessions = Enum.map(sessions, &Map.put(&1, :long?, Claude.long_running?(&1, now, long)))
    needs = sessions |> Enum.filter(&(&1.status == :needs)) |> Enum.sort_by(&unix(&1.since))
    working = sessions |> Enum.filter(&(&1.status == :working)) |> Enum.sort_by(&unix(&1.since))
    idle = sessions |> Enum.filter(&(&1.status == :idle)) |> Enum.sort_by(& &1.name)

    assign(socket,
      needs: needs,
      working: working,
      idle: idle,
      session_count: length(sessions)
    )
  end

  defp derive_github(socket) do
    case socket.assigns.github do
      nil ->
        assign(socket, gh: nil)

      facts ->
        assign(socket, gh: GitHub.summary(facts, socket.assigns.settings, socket.assigns.now))
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
      data-pages={pages(@settings)}
    >
      <div id="track" class={["track", pages(@settings) == 1 && "one-page"]} data-keep="style">
        <section class="page" aria-label={"Page 1, " <> @product}>
          <.header
            brand={@settings.brand}
            title={@product}
            page={0}
            pages={pages(@settings)}
            metas={[@claude_meta, @github_meta]}
          />
          <.needs_banner needs={@needs} />
          <.tiles
            gh={@gh}
            meta={@github_meta}
            dev={if @dev_on?, do: dev_power_tile(@dev, @dev_meta)}
            builds={@builds && Builds.compare(@builds)}
          />
          <%!-- GitHub on the left, Claude sessions (the part that matters most)
               across the wide right side with the token trend under them. --%>
          <div class="middle">
            <div class="left">
              <.actions gh={@gh} meta={@github_meta} />
              <.timeline gh={@gh} now={@now} meta={@github_meta} />
            </div>
            <div class="right">
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
            </div>
          </div>
        </section>

        <section
          :if={pages(@settings) > 1}
          class="page"
          aria-label={"Page 2, " <> @settings.brand.page2_title}
        >
          <.header
            brand={@settings.brand}
            title={@settings.brand.page2_title}
            page={1}
            pages={2}
            metas={[@nr_meta]}
          />
          <.needs_banner needs={@needs} />
          <.new_relic nr={@nr} meta={@nr_meta} now={@now} slots={@settings.new_relic.slots} />
        </section>
      </div>
      <.session_detail :if={@selected} s={@selected} settings={@settings} />
    </div>
    """
  end

  # Page 2 is there only when New Relic is turned on in settings.
  defp pages(settings), do: if(settings.new_relic.enabled, do: 2, else: 1)

  # ---------------------------------------------------------------------------
  # Pieces

  attr :brand, :map, required: true
  attr :title, :string, required: true
  attr :page, :integer, required: true
  attr :metas, :list, required: true
  attr :pages, :integer, required: true

  defp header(assigns) do
    ~H"""
    <header class="header">
      <img :if={@brand.logo} class="logo" src="/brand/logo" alt={@brand.name} />
      <div :if={!@brand.logo} class="wordmark">{@brand.name}</div>
      <div class="divider"></div>
      <div class="page-title">{@title}</div>
      <div class="grow"></div>
      <div class="clockbox" data-fullscreen>
        <div class="clock" data-clock></div>
        <div class="dateline">
          <span data-today></span> · updated <.ago at={oldest(@metas)} stale={stale_after(@metas)} />
        </div>
      </div>
      <%!-- The browser owns the pinned state, so these attributes survive updates.
           With one page there is nothing to rotate, so no pin and no dots. --%>
      <button
        :if={@pages > 1}
        class="pin"
        data-pin
        data-keep="class aria-pressed"
        aria-pressed="false"
        aria-label="Pin this page"
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
      <nav :if={@pages > 1} class="dots" aria-label="Pages">
        <button data-goto="0" class={["dot", @page == 0 && "on"]} aria-label="Page 1"></button>
        <button data-goto="1" class={["dot", @page == 1 && "on"]} aria-label="Page 2"></button>
      </nav>
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

  attr :gh, :map, required: true
  attr :meta, :map, required: true
  # The Dev tile from AWS (awake or asleep), or nil to show the last deploy.
  attr :dev, :map, default: nil
  # Whether prod runs dev's build (:same, :different, :unknown), or nil when
  # that is not read from AWS.
  attr :builds, :atom, default: nil

  defp tiles(assigns) do
    ~H"""
    <section class="tiles" aria-label="Status">
      <%= if @gh do %>
        <.tile label="Main" {main_tile(@gh.main)} />
        <.tile label="Merge queue" {queue_tile(@gh)} />
        <.tile label="Running" {running_tile(@gh.running)} />
        <.tile label="Failed · 24h" {failed_tile(@gh.failures)} />
        <.tile label="Dev" {@dev || dev_tile(@gh.dev)} />
        <.tile label="Prod" {prod_tile(@gh.prod, @builds)} />
      <% else %>
        <div
          :for={label <- ["Main", "Merge queue", "Running", "Failed · 24h", "Dev", "Prod"]}
          class="tile"
        >
          <span class="kicker">{label}</span>
          <span class="dot8 muted"></span>
          <span class="tile-sub">{@meta.error || "loading"}</span>
        </div>
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

  # One slim cell: label, dot, value and a short note, all on one line.
  defp tile(assigns) do
    ~H"""
    <div class="tile">
      <span class="kicker">{@label}</span>
      <span class={["dot8", @tone, @ring && "ring"]}></span>
      <span class={["tile-value", @loud && "loud"]}>{@value}</span>
      <span class="tile-sub">{@sub}<.ago :if={@at} at={@at} fmt="clock" />{@tail}</span>
    </div>
    """
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

  defp queue_tile(%{queue: [first | _] = queue}) do
    %{value: "#{length(queue)} queued", tone: :info, sub: "next ##{first.pr}"}
  end

  defp queue_tile(_), do: %{value: "Empty"}

  defp running_tile([]), do: %{value: "0"}

  defp running_tile(running) do
    names = running |> Enum.map(&running_name/1) |> Enum.uniq() |> Enum.join(", ")
    %{value: "#{length(running)}", tone: :warn, ring: true, sub: names}
  end

  defp running_name(%{pr: pr, name: name}) when is_integer(pr), do: "#{name} on ##{pr}"
  defp running_name(%{name: name}), do: name

  defp failed_tile([]), do: %{value: "0", tone: :ok}

  defp failed_tile([latest | _] = failures) do
    %{
      value: "#{length(failures)}",
      tone: :bad,
      ring: true,
      loud: true,
      sub: "last ",
      at: latest.updated_at
    }
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
        <button class="link-button theme-toggle" data-theme-toggle aria-label="Switch light or dark">
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
        <a class="link-button" href="/settings">Settings</a>
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
            machine={@archive_on? && @machine}
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
      <%= for {group, label} <- [claude: "Claude", codex: "Codex", korium: "Korium", github: "GitHub"],
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
      Session numbers count on the day a session last worked.
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
        <span class="sc-name">{@a.title || short_id(@a.session_id)}</span>
        <span class="grow"></span>
        <span class={["badge", archive_badge_class(@a, @live?)]}>{archive_badge(@a, @live?)}</span>
      </div>
      <div class="sc-meta">
        <span class="sc-id">{short_id(@a.session_id)}</span>
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

  defp short_id(nil), do: ""
  defp short_id(id), do: String.slice(id, 0, 8)

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
      class={["session-card", @s.status == :needs && "needs", @machine && "tappable"]}
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
        <span :if={@s.folder} class="sc-folder">{@s.folder}</span>
        <span :if={@s[:started_by]} class="acct">from {@s.started_by}</span>
      </div>
      <div class="sc-task">{if @s.status == :needs, do: @s.why, else: @s.task}</div>

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
          <h2 class="detail-title">{@s.title || short_id(@s.session_id)}</h2>
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
          <span>{short_id(@s.session_id)}</span>
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
                {pr["repo"]} #{pr["number"]}
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

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :any, default: nil

  defp stat(assigns) do
    ~H"""
    <div class="stat">
      <span class="kicker">{@label}</span>
      <span class="stat-value">{@value || "-"}</span>
      <span :if={@note} class="stat-note">{@note}</span>
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
  # GitHub Actions

  attr :gh, :map, required: true
  attr :meta, :map, required: true

  defp actions(assigns) do
    ~H"""
    <section class="actions" aria-label="GitHub Actions">
      <div class="heading-row">
        <h2 class="kicker">GitHub Actions · running now</h2>
        <.freshness meta={@meta} />
      </div>
      <%= if @gh do %>
        <div :if={@gh.running == []} class="empty-box">Nothing running.</div>
        <div :for={r <- Enum.take(@gh.running, 2)} class="run-card">
          <div class="row baseline">
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
            <span class="rc-name">{r.name}</span>
            <span class="rc-what">{r.what}</span>
            <span class="rc-elapsed"><.ago at={r.started_at} fmt="for" /></span>
          </div>
          <div class="bar">
            <div class="bar-fill" style={"width: #{r.progress}%"}></div>
          </div>
          <div class="rc-step">{r.step}</div>
        </div>

        <div :if={@gh.prs != []} class="heading-row gap-top">
          <h2 class="kicker">Pull requests · {length(@gh.prs)} open</h2>
        </div>
        <div :if={@gh.prs != []} class="list">
          <div :for={p <- Enum.take(@gh.prs, 2)} class="pr-row">
            <span class={["gate-icon", "gate-#{p.gate}"]}>{gate_icon(p.gate)}</span>
            <span class="pr-title">#{p.number} {p.title}</span>
            <span class="pr-gate">{gate_words(p.gate, p.draft)}</span>
            <span class="pr-time"><.ago at={p.updated_at} /></span>
          </div>
        </div>

        <h2 class="kicker gap-top">Recent</h2>
        <div class="list recent" data-clip>
          <div :for={x <- @gh.recent} class="recent-row">
            <span class={["icon", result_class(x.conclusion)]}>{result_icon(x.conclusion)}</span>
            <span class="rr-text">
              <span class="rr-name">{x.label}</span>
              <span class="rr-what">{x.what}</span>
            </span>
            <span class="rr-when">
              <span class="rr-time"><.ago at={x.updated_at} fmt="clock" /></span>
              <span class="rr-took">{took(x.took)}</span>
            </span>
          </div>
        </div>
      <% else %>
        <div class="empty-note">{@meta.error || "Loading from GitHub…"}</div>
      <% end %>
    </section>
    """
  end

  defp gate_icon(:passed), do: "✓"
  defp gate_icon(:failed), do: "✗"
  defp gate_icon(:running), do: "●"
  defp gate_icon(_), do: "–"

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

  attr :gh, :map, required: true
  attr :now, :any, required: true
  attr :meta, :map, required: true

  @window 6 * 3600

  defp timeline(assigns) do
    assigns = assign(assigns, hours: hour_marks(assigns.now))

    ~H"""
    <section class="timeline" aria-label="Runs, last 6 hours">
      <div class="heading-row">
        <h2 class="kicker">Runs · last 6 hours</h2>
        <span class="grow"></span>
        <span class="legend"><span class="sw pass"></span>passed</span>
        <span class="legend"><span class="sw fail"></span>failed</span>
        <span class="legend"><span class="sw run"></span>running</span>
      </div>
      <div :for={lane <- (@gh && @gh.lanes) || []} class="lane">
        <span class="lane-name">{lane.label}</span>
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
    </section>
    """
  end

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
      " Set new_relic.api_key_ref in settings.exs to your 1Password reference (for example \"op://Vault/Item/credential\"), " <>
      "set new_relic.account_id and new_relic.checks, then restart the board."
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
