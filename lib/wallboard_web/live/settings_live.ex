defmodule WallboardWeb.SettingsLive do
  @moduledoc """
  The settings page, at /settings: what the board is set to, the
  devices approved to open it (and a button to remove one), the machines
  that stream to this hub (and a button to disconnect one), and the
  sessions saved from each machine.

  It shows settings and cannot change them. What it can still do changes
  no setting: remove a device, disconnect a machine, and let the mailbox
  ask again about a repository that was ignored there. Settings are
  changed on the machine itself, in the VitalAIze app or with `vitalaize
  setup` (see `Wallboard.Setup`), which save them and restart only what a
  change needs.

  Who may open it: anyone on this Mac itself, or, when other devices need
  approval, an approved device (see `WallboardWeb.Auth.may_decide?/1`).
  Otherwise other devices on the network are turned away, since the page
  holds the phone number and the AWS profiles.
  """

  use WallboardWeb, :live_view

  alias Wallboard.{Link, Poller, Settings, Store}
  alias Wallboard.Archive.Collector
  alias WallboardWeb.Auth

  @impl true
  def mount(_params, session, socket) do
    who = if connected?(socket), do: Auth.who(socket, session), else: %{local?: false}
    allowed? = connected?(socket) and Auth.may_decide?(who)

    # The machines list follows machines coming and going, and new ones
    # being approved.
    if allowed? do
      Phoenix.PubSub.subscribe(Wallboard.PubSub, "link")
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Wallboard.Mailbox.topic())
    end

    socket =
      assign(socket,
        allowed?: allowed?,
        who: who,
        connected?: connected?(socket),
        notice: nil,
        confirm_disconnect: nil
      )

    {:ok, if(allowed?, do: load(socket), else: socket)}
  end

  @doc "True when a connection comes from this Mac (see `WallboardWeb.Auth.this_machine?/1`)."
  defdelegate this_mac?(addr), to: Auth, as: :this_machine?

  defp load(socket) do
    settings = Settings.get()

    assign(socket,
      settings: settings,
      values: values(settings),
      machines: machines(settings),
      linked: linked(settings),
      linked_readable?: not Link.hub?(settings) or Link.Machines.readable?(settings),
      ignored_repos: Wallboard.RepoPrompts.ignored(),
      devices: Wallboard.Devices.list(),
      release?: System.get_env("RELEASE_ROOT") != nil
    )
  end

  # How long "Tap again" stands after the first Disconnect tap.
  @confirm_ms 8_000

  @doc """
  The page's field values (see `Wallboard.Settings.shown/1`): a secret
  that is set goes to the browser as dots, never as itself.
  """
  defdelegate values(settings), to: Settings, as: :shown

  defdelegate unmask(values, shown, current), to: Settings

  defp machines(%{archive: %{enabled: true}}) do
    Store.query(
      "SELECT machine, count(*) AS sessions, max(ended_at) AS last FROM sessions GROUP BY machine ORDER BY last DESC",
      []
    )
  end

  defp machines(_), do: []

  # The machines that stream to this hub, or nil when it takes none.
  defp linked(settings) do
    if Link.hub?(settings), do: Link.Machines.list(settings, local_sessions())
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp local_sessions do
    for name <- [:claude, :codex], reduce: 0 do
      n -> n + length((Poller.snapshot(name).facts || %{})[:sessions] || [])
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @impl true
  def handle_info({:link, what, _machine}, socket) when what in [:up, :down],
    do: {:noreply, relist(socket)}

  def handle_info({:link, :hello, _machine, _info}, socket), do: {:noreply, relist(socket)}
  def handle_info({:mailbox, :changed}, socket), do: {:noreply, socket |> reread() |> relist()}

  # A device was approved or removed, here or on another screen.
  def handle_info({:devices, :changed}, %{assigns: %{allowed?: true}} = socket),
    do: {:noreply, assign(socket, devices: Wallboard.Devices.list())}

  # Only the latest question's own timer ends it.
  def handle_info({:forget_disconnect, ref}, socket) do
    if socket.assigns[:confirm_ref] == ref,
      do: {:noreply, assign(socket, confirm_disconnect: nil)},
      else: {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp relist(%{assigns: %{allowed?: true, settings: settings}} = socket) do
    assign(socket,
      linked: linked(settings),
      linked_readable?: not Link.hub?(settings) or Link.Machines.readable?(settings),
      ignored_repos: Wallboard.RepoPrompts.ignored()
    )
  end

  defp relist(socket), do: socket

  # A repo tracked from the mailbox while this page is open shows in its
  # list at once. The page sends no settings back, so one drawn before a
  # Track cannot undo it.
  defp reread(%{assigns: %{allowed?: true}} = socket) do
    settings = Settings.get()
    assign(socket, settings: settings, values: values(settings))
  end

  defp reread(socket), do: socket

  # Every change on this page is the owner's to make, and that is asked
  # again each time: this device may have been removed since the page
  # opened.
  @impl true
  def handle_event(event, params, socket) do
    cond do
      not socket.assigns.allowed? ->
        {:noreply, socket}

      not Auth.may_decide?(socket.assigns.who) ->
        {:noreply,
         assign(socket, confirm_disconnect: nil, notice: "Open this page again to do that.")}

      true ->
        event(event, params, socket)
    end
  end

  # Disconnect takes two taps: the first asks, the second revokes the
  # machine's certificate, which closes its stream at once and refuses it
  # from then on. The question lapses after a few seconds, so a tap much
  # later is a first tap again.
  defp event("disconnect", %{"machine" => machine}, socket) do
    cond do
      socket.assigns.confirm_disconnect != machine ->
        ref = make_ref()
        Process.send_after(self(), {:forget_disconnect, ref}, @confirm_ms)
        {:noreply, assign(socket, confirm_disconnect: machine, confirm_ref: ref)}

      true ->
        notice =
          case Link.Hub.revoke(machine) do
            {:ok, _} -> "#{machine} is disconnected. To connect it again, pair it again."
            _ -> "#{machine} could not be disconnected just now. Try again in a moment."
          end

        {:noreply, socket |> relist() |> assign(confirm_disconnect: nil, notice: notice)}
    end
  end

  # Signs a device out at once; it has to be approved again to come back.
  # One tap: nothing is lost that a new approval does not give back.
  defp event("remove_device", %{"id" => id}, socket) do
    notice =
      case Wallboard.Devices.remove(id) do
        :ok -> "The device is removed. To open the board again, it has to be approved again."
        {:error, :gone} -> "That device was already removed."
        _ -> "That did not work just now. Try again in a moment."
      end

    {:noreply, assign(socket, devices: Wallboard.Devices.list(), notice: notice)}
  end

  # Undoes an Ignore from the mailbox: work in that repo asks again.
  defp event("ask_again", %{"repo" => repo}, socket) do
    notice =
      case Wallboard.RepoPrompts.ask_again(repo) do
        :ok -> "The mailbox will ask about #{repo} the next time someone works in it."
        _ -> "That did not work just now. Try again in a moment."
      end

    {:noreply, assign(socket, ignored_repos: Wallboard.RepoPrompts.ignored(), notice: notice)}
  end

  defp event("refresh_archive", _params, socket) do
    Collector.refresh()
    {:noreply, assign(socket, notice: "Saving every session again in the background.")}
  end

  defp event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(%{connected?: false} = assigns) do
    ~H"""
    <div class="settings-page">
      <p class="detail-note">Loading settings…</p>
    </div>
    """
  end

  def render(%{allowed?: false} = assigns) do
    ~H"""
    <div class="settings-page">
      <h1 class="settings-title">Settings</h1>
      <p class="detail-note">
        Open this page on the machine that runs the board. To see it from another device,
        first turn on Other devices need approval on that machine, then approve this device.
      </p>
      <a class="link-button" href="/">Back to the board</a>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="settings-page">
      <div class="row">
        <h1 class="settings-title">Settings</h1>
        <span class="grow"></span>
        <a class="link-button" href="/">Back to the board</a>
      </div>
      <p :if={@notice} class="settings-notice">{@notice}</p>
      <p class="settings-where">
        Settings are shown here and changed on this machine: open the VitalAIze app, or run
        <code>vitalaize setup</code>
        in a terminal. Either saves the change and restarts only what needs it.
      </p>

      <section :if={@settings.approve_devices} class="settings-section">
        <div class="heading-row">
          <h2 class="kicker">Approved devices</h2>
          <span class="stat-note">browsers on other devices that may open this board</span>
        </div>
        <div class="machine-list">
          <div :for={d <- @devices} class="machine-row">
            <b>{d.name}</b>
            <span>{d.address}</span>
            <span>Approved {day(d.approved_at)} · last opened {day(d.seen_at)}</span>
            <span></span>
            <button class="machine-disconnect" phx-click="remove_device" phx-value-id={d.id}>
              Remove
            </button>
          </div>
        </div>
        <p :if={@devices == []} class="detail-note">No device is approved yet.</p>
        <p class="stat-note">
          A new device shows a code; approve it in the mailbox on the board. An approved device
          can also change what this page changes and approve others. Remove signs it out at once.
        </p>
      </section>

      <section :if={@linked} class="settings-section">
        <div class="heading-row">
          <h2 class="kicker">Connected machines</h2>
          <span class="stat-note">
            each machine watches its own Claude and Codex folders and reports all agent work
          </span>
        </div>
        <div class="machine-list">
          <div :for={m <- @linked} class="machine-row">
            <b>{m.name}{if m.hub?, do: " (this hub)"}</b>
            <span>{m.os || "not connected yet"}</span>
            <span>{seen(m)} · {sessions(m.sessions)}</span>
            <span class="machine-folders">{Enum.join(m.folders, ", ")}</span>
            <button
              :if={!m.hub?}
              class={["machine-disconnect", @confirm_disconnect == m.name && "sure"]}
              phx-click="disconnect"
              phx-value-machine={m.name}
            >
              {if @confirm_disconnect == m.name, do: "Tap again", else: "Disconnect"}
            </button>
            <span :if={m.hub?}></span>
          </div>
        </div>
        <p :if={!@linked_readable?} class="bad-ink stat-note">
          The list of machines cannot be read just now, so machines may be missing here.
          None of them has been removed.
        </p>
        <p class="stat-note">
          A new machine asks to connect with a code; approve it in the mailbox on the board.
          Disconnect takes a machine's certificate away at once.
        </p>
      </section>

      <section
        :for={{section, fields} <- Settings.editable(@settings.role)}
        class="settings-section"
      >
        <h2 class="kicker">{section}</h2>
        <dl class="settings-values">
          <div :for={{path, label, type, _restart, _help} <- fields} class="settings-value">
            <dt>{label}</dt>
            <dd>{shown(type, @values[Enum.join(path, ".")])}</dd>
          </div>
          <%!-- Ask again changes what the mailbox asks, not a setting, so it stays here. --%>
          <div :if={section == "GitHub" and @ignored_repos != []} class="settings-value">
            <dt>Ignored repositories</dt>
            <dd>
              <div :for={repo <- @ignored_repos} class="row ignored-repo">
                <span>{repo}</span>
                <button type="button" class="link-button" phx-click="ask_again" phx-value-repo={repo}>
                  Ask again
                </button>
              </div>
              <p class="detail-note">
                You chose Ignore for these in the mailbox, so work in them never asks to be tracked.
              </p>
            </dd>
          </div>
        </dl>
      </section>

      <section :if={@settings.archive.enabled} class="settings-section">
        <h2 class="kicker">Saved sessions by Mac</h2>
        <table class="dtable settings-table">
          <tr>
            <th></th>
            <th>Sessions</th>
            <th>Last active</th>
          </tr>
          <tr :for={m <- @machines}>
            <td>{m.machine}</td>
            <td>{m.sessions}</td>
            <td>{m.last && Calendar.strftime(DateTime.from_unix!(m.last), "%b %-d")}</td>
          </tr>
        </table>
        <button class="link-button" phx-click="refresh_archive">Save this Mac's sessions again</button>
        <p class="stat-note">Database: {@settings.archive.path}</p>
      </section>
    </div>
    """
  end

  defp seen(%{connected?: true}), do: "Seen now"
  defp seen(%{seen_at: nil}), do: "Never seen"

  defp seen(%{seen_at: at}) do
    case System.os_time(:second) - at do
      s when s < 90 -> "Seen a minute ago"
      s when s < 3600 -> "Seen #{div(s, 60)} min ago"
      s when s < 172_800 -> "Seen #{div(s, 3600)} h ago"
      s -> "Seen #{div(s, 86_400)} days ago"
    end
  end

  defp day(nil), do: "never"

  # This machine's own day, as the rest of the board counts days.
  defp day(at) do
    {date, _} =
      at
      |> DateTime.from_unix!()
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    date |> Date.from_erl!() |> Calendar.strftime("%b %-d")
  end

  defp sessions(1), do: "1 session"
  defp sessions(n), do: "#{n} sessions"

  # A value as the page shows it: a secret as dots, a list one per line.
  defp shown(_type, value) when value in [nil, ""], do: "not set"
  defp shown(:boolean, "true"), do: "yes"
  defp shown(:boolean, _), do: "no"

  defp shown(type, text) when type in [:lines, :repos, :folders],
    do: String.replace(text, "\n", ", ")

  defp shown(_type, text), do: text
end
