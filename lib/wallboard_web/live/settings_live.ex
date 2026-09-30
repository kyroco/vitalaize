defmodule WallboardWeb.SettingsLive do
  @moduledoc """
  The settings page, at /settings: change the board without editing
  settings.exs, and connect other Macs.

  Who may open it: anyone on this Mac itself, or, when the board has a
  password, anyone who gave it (the router already checked). Without a
  password, other devices on the network are turned away, since the page
  holds the phone number, the AWS profiles and the key other Macs use.
  """

  use WallboardWeb, :live_view

  alias Wallboard.{Settings, Store}
  alias Wallboard.Archive.{Collector, MachineKeys}
  alias WallboardWeb.IngestController

  @impl true
  def mount(_params, _session, socket) do
    allowed? = connected?(socket) and allowed?(socket)

    socket =
      assign(socket,
        allowed?: allowed?,
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

  defp allowed?(socket) do
    settings = Settings.get()

    local? =
      case get_connect_info(socket, :peer_data) do
        %{address: addr} -> this_mac?(addr)
        _ -> false
      end

    local? or settings.token != nil
  end

  @doc """
  True when a connection comes from this Mac: from localhost, or from one of
  this Mac's own network addresses (opening the board by its network
  address, like http://192.168.1.20:4747, connects from that address).
  Another device cannot pass as one of these: it would never get the
  replies needed to finish connecting.
  """
  def this_mac?(addr), do: addr |> unmap() |> then(&(loopback?(&1) or &1 in own_addresses()))

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  # An IPv4 address seen through IPv6 (::ffff:192.168.1.20) is the IPv4 one.
  defp unmap({0, 0, 0, 0, 0, 65535, a, b}),
    do: {div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)}

  defp unmap(addr), do: addr

  defp own_addresses do
    case :inet.getifaddrs() do
      {:ok, ifs} -> for {_name, opts} <- ifs, {:addr, a} <- opts, do: a
      _ -> []
    end
  end

  @doc false
  def load(socket) do
    settings = Settings.get()

    assign(socket,
      settings: settings,
      values: values(settings),
      hub_url: IngestController.hub_url(settings),
      key: if(settings.archive.enabled, do: MachineKeys.connect_key()),
      keys: if(settings.archive.enabled, do: MachineKeys.list(), else: []),
      old_tries: if(settings.archive.enabled, do: MachineKeys.old_tries(), else: []),
      machines: machines(settings),
      release?: System.get_env("RELEASE_ROOT") != nil
    )
  end

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

  @impl true
  def handle_event(_event, _params, %{assigns: %{allowed?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("save", %{"s" => values}, socket) do
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

  def handle_event("restart", _params, %{assigns: %{release?: true}} = socket) do
    # The login item starts the board again as soon as it stops.
    Task.start(fn ->
      Process.sleep(500)
      System.stop(0)
    end)

    {:noreply, assign(socket, notice: "Restarting. This page reconnects in a few seconds.")}
  end

  def handle_event("restart", _params, socket),
    do: {:noreply, assign(socket, notice: "Restart the board by hand to apply these changes.")}

  def handle_event("toggle_key", _params, socket),
    do: {:noreply, assign(socket, show_key?: !socket.assigns.show_key?)}

  def handle_event("new_key", _params, %{assigns: %{confirm_new_key?: false}} = socket),
    do: {:noreply, assign(socket, confirm_new_key?: true)}

  def handle_event("new_key", _params, socket) do
    MachineKeys.new_connect_key()

    {:noreply,
     socket
     |> load()
     |> assign(
       confirm_new_key?: false,
       show_key?: true,
       notice: "New connect key made. Machines already connected keep sending."
     )}
  end

  # Takes one machine's key away, after a second tap on the same button.
  def handle_event("disconnect", %{"key" => key_id}, socket) do
    if socket.assigns.confirm_disconnect == key_id do
      machine = Enum.find_value(socket.assigns.keys, &(&1.key_id == key_id && &1.machine))
      MachineKeys.revoke(key_id)

      {:noreply,
       socket
       |> load()
       |> assign(
         confirm_disconnect: nil,
         notice: "#{machine} is disconnected. It sends nothing until it is connected again."
       )}
    else
      {:noreply, assign(socket, confirm_disconnect: key_id)}
    end
  end

  def handle_event("refresh_archive", _params, socket) do
    Collector.refresh()
    {:noreply, assign(socket, notice: "Saving every session again in the background.")}
  end

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
        <h2 class="kicker">Connect another machine</h2>
        <p class="detail-note">
          Run this once in Terminal on the other Mac or Linux machine. It gives that machine a key of
          its own, saves a small script, and adds hooks to its Claude settings (backing them up
          first). After that, each session is sent here when a turn ends and when it closes, in the
          background, so Claude never waits on it.
        </p>
        <p class="detail-note">
          The connect key below never leaves the machine you paste it on. Each request that machine
          sends is signed with its own key instead, so nobody on the network can read a key or send
          as that machine. The sessions themselves still cross the network as they are.
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
              do: "Tap again: machines already connected keep sending",
              else: "Make a new connect key"}
          </button>
        </div>
        <p class="stat-note">
          Other Macs reach this board at {@hub_url}. This Mac does not need it: the board reads its own sessions.
        </p>
      </section>

      <section :if={@key && @old_tries != []} class="settings-section">
        <h2 class="kicker">Machines to connect again</h2>
        <p class="detail-note">
          These machines were connected by VitalAIze 0.2.0 or earlier. They still send with the old
          shared key, which this hub no longer takes, so nothing from them arrives. On each one, run
          the connect command above in Terminal (or run VitalAIze's setup again there and pick
          Collector only).
        </p>
        <table class="dtable settings-table">
          <tr>
            <th></th>
            <th>Last tried</th>
          </tr>
          <tr :for={t <- @old_tries}>
            <td>{t.machine}</td>
            <td>{day(t.at)}</td>
          </tr>
        </table>
      </section>

      <section :if={@key} class="settings-section">
        <h2 class="kicker">Connected machines</h2>
        <p :if={@keys == []} class="detail-note">
          No machine is connected yet.
        </p>
        <table :if={@keys != []} class="dtable settings-table">
          <tr>
            <th></th>
            <th>Connected</th>
            <th>Last sent</th>
            <th></th>
          </tr>
          <tr :for={k <- @keys}>
            <td>{k.machine}</td>
            <td>{day(k.created_at)}</td>
            <td>{if k.last_used_at, do: day(k.last_used_at), else: "not yet"}</td>
            <td>
              <button class="link-button" phx-click="disconnect" phx-value-key={k.key_id}>
                {if @confirm_disconnect == k.key_id,
                  do: "Tap again to disconnect",
                  else: "Disconnect"}
              </button>
            </td>
          </tr>
        </table>
        <p class="stat-note">
          Disconnecting a machine takes its key away and leaves the others as they are.
        </p>
      </section>

      <section :if={@key} class="settings-section">
        <h2 class="kicker">Saved sessions by machine</h2>
        <table class="dtable settings-table">
          <tr>
            <th></th>
            <th>Sessions</th>
            <th>Last active</th>
          </tr>
          <tr :for={m <- @machines}>
            <td>{m.machine}</td>
            <td>{m.sessions}</td>
            <td>{m.last && day(m.last)}</td>
          </tr>
        </table>
        <button class="link-button" phx-click="refresh_archive">Save this Mac's sessions again</button>
        <p class="stat-note">Database: {@settings.archive.path}</p>
      </section>
    </div>
    """
  end

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

  @doc """
  The command another machine runs to connect. The key goes to the script
  on that machine, never over the network: the script only signs with it.
  """
  def install_command(hub, key),
    do: ~s(curl -fsS #{hub}/ingest/install.sh | WALLBOARD_KEY="#{key}" sh)

  defp day(unix), do: Calendar.strftime(DateTime.from_unix!(unix), "%b %-d")
end
