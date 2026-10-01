defmodule WallboardWeb.SettingsLive do
  @moduledoc """
  The settings page, at /settings: change the board without editing
  settings.exs, connect other Macs, and see or disconnect the machines
  that stream to this hub.

  Who may open it: anyone on this Mac itself, or, when the board has a
  password, anyone who gave it (the router already checked). Without a
  password, other devices on the network are turned away, since the page
  holds the phone number, the AWS profiles and the key other Macs use.
  """

  use WallboardWeb, :live_view

  alias Wallboard.{Link, Poller, Settings, Store}
  alias Wallboard.Archive.{Collector, Ingest}
  alias WallboardWeb.{Auth, IngestController}

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
        errors: %{},
        notice: nil,
        restart?: false,
        show_key?: false,
        confirm_new_key?: false,
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
      hub_url: IngestController.hub_url(settings),
      key: if(settings.archive.enabled, do: Ingest.token()),
      machines: machines(settings),
      linked: linked(settings),
      linked_readable?: not Link.hub?(settings) or Link.Machines.readable?(settings),
      release?: System.get_env("RELEASE_ROOT") != nil
    )
  end

  # How long "Tap again" stands after the first Disconnect tap.
  @confirm_ms 8_000

  @kept "••••••••"

  @doc """
  The page's field values. A secret that is set (a webhook address, a key,
  the board password) goes to the browser as dots, never as itself, so
  anyone who can open the page cannot read it from the page source.
  """
  def values(settings) do
    for {_, fs} <- Settings.editable(), {path, _, type, _, _} <- fs, into: %{} do
      value = Settings.current(settings, path, type)
      text = if type == :secret and value != nil, do: @kept, else: to_text(type, value)
      {Enum.join(path, "."), text}
    end
  end

  @doc """
  Turns a secret that came back as dots into the value it stands for now.
  `shown` is the settings the page was drawn from: only a secret that was set
  there went out as dots, so dots typed into an empty field are kept as
  typed, and dots from a page drawn before the secret changed elsewhere
  follow the newest value.
  """
  def unmask(values, shown, current) do
    for {_, fs} <- Settings.editable(), {path, _, :secret, _, _} <- fs, reduce: values do
      acc ->
        key = Enum.join(path, ".")

        if Map.get(acc, key) == @kept and get_in(shown, path) != nil,
          do: Map.put(acc, key, to_text(:secret, get_in(current, path))),
          else: acc
    end
  end

  defp to_text(_, nil), do: ""
  defp to_text(type, list) when type in [:lines, :repos], do: Enum.join(List.wrap(list), "\n")
  defp to_text(_, v), do: to_string(v)

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
  def handle_info({:mailbox, :changed}, socket), do: {:noreply, relist(socket)}

  # Only the latest question's own timer ends it.
  def handle_info({:forget_disconnect, ref}, socket) do
    if socket.assigns[:confirm_ref] == ref,
      do: {:noreply, assign(socket, confirm_disconnect: nil)},
      else: {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp relist(%{assigns: %{allowed?: true, settings: settings}} = socket),
    do:
      assign(socket,
        linked: linked(settings),
        linked_readable?: not Link.hub?(settings) or Link.Machines.readable?(settings)
      )

  defp relist(socket), do: socket

  # Every change on this page is the owner's to make, and that is asked
  # again each time: the board password may have changed since the page
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

  defp event("save", %{"s" => values}, socket) do
    before = Settings.get()

    case Settings.check(unmask(values, socket.assigns.settings, before), Settings.base()) do
      {:ok, overrides} ->
        after_ = Settings.save_overrides(overrides)

        restart? =
          socket.assigns.restart? or
            Enum.any?(restart_paths(), &(get_in(before, &1) != get_in(after_, &1)))

        {:noreply,
         socket
         |> load()
         |> assign(
           errors: %{},
           restart?: restart?,
           notice: "Saved. Most changes apply within a minute."
         )}

      {:error, errors} ->
        {:noreply, assign(socket, errors: errors, values: values, notice: nil)}
    end
  end

  defp event("restart", _params, %{assigns: %{release?: true}} = socket) do
    # The login item starts the board again as soon as it stops.
    Task.start(fn ->
      Process.sleep(500)
      System.stop(0)
    end)

    {:noreply, assign(socket, notice: "Restarting. This page reconnects in a few seconds.")}
  end

  defp event("restart", _params, socket),
    do: {:noreply, assign(socket, notice: "Restart the board by hand to apply these changes.")}

  defp event("toggle_key", _params, socket),
    do: {:noreply, assign(socket, show_key?: !socket.assigns.show_key?)}

  defp event("new_key", _params, %{assigns: %{confirm_new_key?: false}} = socket),
    do: {:noreply, assign(socket, confirm_new_key?: true)}

  defp event("new_key", _params, socket) do
    Store.put_meta(
      "ingest_token",
      24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    )

    {:noreply,
     socket
     |> load()
     |> assign(
       confirm_new_key?: false,
       show_key?: true,
       notice: "New key made. Run the connect command again on each other Mac."
     )}
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

  defp event("refresh_archive", _params, socket) do
    Collector.refresh()
    {:noreply, assign(socket, notice: "Saving every session again in the background.")}
  end

  defp event(_event, _params, socket), do: {:noreply, socket}

  defp restart_paths do
    for {_, fs} <- Settings.editable(), {path, _, _, true, _} <- fs, do: path
  end

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
        Open this page on the Mac that runs the board. To change settings from another device,
        first give the board a password on that Mac.
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
      <div :if={@restart?} class="settings-restart">
        Some changes apply when the board restarts.
        <button class="link-button" phx-click="restart">Restart now</button>
      </div>

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

      <form phx-submit="save" class="settings-form">
        <section :for={{section, fields} <- Settings.editable()} class="settings-section">
          <h2 class="kicker">{section}</h2>
          <label :for={{path, label, type, restart, help} <- fields} class="settings-field">
            <span class="settings-label">
              {label}<span :if={restart} class="muted-ink"> · after restart</span>
            </span>
            <.field
              name={"s[#{Enum.join(path, ".")}]"}
              type={type}
              value={@values[Enum.join(path, ".")]}
            />
            <span :if={help} class="stat-note">{help}</span>
            <span :if={@errors[Enum.join(path, ".")]} class="bad-ink stat-note">
              {@errors[Enum.join(path, ".")]}
            </span>
          </label>
        </section>
        <div class="row">
          <button type="submit" class="settings-save">Save</button>
          <span class="stat-note">
            Values saved here win over settings.exs.
          </span>
        </div>
      </form>

      <section :if={@key} class="settings-section">
        <h2 class="kicker">Connect another Mac</h2>
        <p class="detail-note">
          Run this once in Terminal on the other Mac. It saves a small script and adds two hooks to
          that Mac's Claude settings (backing them up first). After that, each session is sent here
          when a turn ends and when it closes, in the background, so Claude never waits on it.
        </p>
        <p class="detail-note">
          When that Mac has Codex, its Codex sessions come too, through two hooks in Codex's
          hooks.json. Codex runs a new hook only once you trust it, so type /hooks in Codex there
          afterwards and trust the two wallboard-upload.sh hooks.
        </p>
        <pre class="settings-code">{install_command(@hub_url, if(@show_key?, do: @key, else: "••••••••"))}</pre>
        <div class="row">
          <button class="link-button" phx-click="toggle_key">
            {if @show_key?, do: "Hide key", else: "Show key"}
          </button>
          <button class="link-button" phx-click="new_key">
            {if @confirm_new_key?,
              do: "Tap again: other Macs stop sending until reconnected",
              else: "Make a new key"}
          </button>
        </div>
        <p class="stat-note">
          Other Macs reach this board at {@hub_url}. This Mac does not need it: the board reads its own sessions.
        </p>
      </section>

      <section :if={@key} class="settings-section">
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

  defp sessions(1), do: "1 session"
  defp sessions(n), do: "#{n} sessions"

  attr :name, :string, required: true
  attr :type, :any, required: true
  attr :value, :string, default: ""

  defp field(%{type: {:choice, options}} = assigns) do
    assigns = assign(assigns, options: options)

    ~H"""
    <select name={@name} class="settings-input">
      <option :for={o <- @options} value={o} selected={o == @value}>{o}</option>
    </select>
    """
  end

  # An unticked box sends nothing, so a hidden "false" goes first and the
  # box, when ticked, replaces it.
  defp field(%{type: :boolean} = assigns) do
    ~H"""
    <input type="hidden" name={@name} value="false" />
    <input
      type="checkbox"
      name={@name}
      value="true"
      checked={@value == "true"}
      class="settings-check"
    />
    """
  end

  defp field(%{type: type} = assigns) when type in [:lines, :repos] do
    ~H"""
    <textarea name={@name} class="settings-input" rows={if @type == :repos, do: 6, else: 3}>{@value}</textarea>
    """
  end

  defp field(%{type: :secret} = assigns) do
    ~H"""
    <input type="password" name={@name} value={@value} class="settings-input" autocomplete="off" />
    """
  end

  defp field(%{type: :integer} = assigns) do
    ~H"""
    <input type="number" min="0" name={@name} value={@value} class="settings-input" />
    """
  end

  defp field(assigns) do
    ~H"""
    <input type="text" name={@name} value={@value} class="settings-input" autocomplete="off" />
    """
  end

  defp install_command(hub, key),
    do: ~s(curl -fsS -H "Authorization: Bearer #{key}" #{hub}/ingest/install.sh | sh)
end
