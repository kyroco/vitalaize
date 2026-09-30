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
  alias Wallboard.Archive.{Collector, Ingest}
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
        confirm_new_key?: false
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

  defp load(socket) do
    settings = Settings.get()

    assign(socket,
      settings: settings,
      values: values(settings),
      hub_url: IngestController.hub_url(settings),
      key: if(settings.archive.enabled, do: Ingest.token()),
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
      value = get_in(settings, path)
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
  defp to_text(:lines, list), do: Enum.join(List.wrap(list), "\n")
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
        <h2 class="kicker">Connect another Mac</h2>
        <p class="detail-note">
          Run this once in Terminal on the other Mac. It saves a small script and adds two hooks to
          that Mac's Claude settings (backing them up first). After that, each session is sent here
          when a turn ends and when it closes, in the background, so Claude never waits on it.
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

  defp field(%{type: :lines} = assigns) do
    ~H"""
    <textarea name={@name} class="settings-input" rows="3">{@value}</textarea>
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
