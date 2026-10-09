defmodule Wallboard.Devices do
  @moduledoc """
  Browsers on other devices that may open the board, when the board asks
  for approval (the `approve_devices` setting).

  A browser that is not approved yet asks here. It is given a six-digit
  code to show, and the board's mailbox shows the same code with Approve
  and Refuse (`Wallboard.Mailbox.NewDevice`). The browser looks again every
  few seconds; once approved, it is handed a key of its own, which its
  session cookie keeps from then on. The board's own machine never asks:
  see `WallboardWeb.Auth`.

  Waiting requests live only in memory: a restart forgets them, and the
  browser simply asks again. Approved devices are kept in `devices.json`
  in a `browsers` folder beside the database, readable by this user only,
  with a hash of each key, never the key itself. Removing a device signs
  it out at once, since every page and every decision checks the list.

  The door has limits like machine pairing's (`Wallboard.Pairing.Door`):
  two waiting requests per address, only so many in the mailbox, a few asks
  a minute from one address, and a request ends after ten minutes. Each
  request belongs to the browser that made it: only the session holding its
  id, from the address that asked, collects the approval.
  """

  use GenServer
  require Logger

  @topic "devices"

  @limits %{
    max_pending: 5,
    max_per_address: 2,
    starts_per_minute: 6,
    starts_per_minute_all: 30,
    # A waiting request ends this long after it was made, whatever happens.
    expire_ms: 10 * 60_000,
    # And it leaves the mailbox once its browser stops looking for this long.
    gone_ms: 60_000,
    # Last seen is written at most this often for one device.
    seen_ms: 60 * 60_000
  }

  # -- Client --

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Where the approved devices and the cookie key live for these settings."
  def dir(settings) do
    settings
    |> get_in([:archive, :path])
    |> Wallboard.Settings.db_path()
    |> Path.dirname()
    |> Path.join("browsers")
  end

  @doc "The PubSub topic that hears `{:devices, :changed}` when a device is approved or removed."
  def topic, do: @topic

  @doc """
  A browser at `address` asks to be approved. `agent` is its User-Agent,
  only to name it in the mailbox. `{:ok, id, code}`, or `{:error, :busy}`
  when the door has no room for it now.
  """
  def ask(address, agent), do: call({:ask, address, agent}, {:error, :busy})

  @doc """
  Where the request `id` stands, asked by the browser that made it:
  `{:pending, code}`; `{:approved, key}`, the device's key, the same on
  every look until the request runs out (so two tabs asking at once both
  get it); `:refused`; or `:gone`.
  """
  def status(id, address), do: call({:status, id, address}, :gone)

  @doc "True when `key` belongs to an approved device that has not been removed."
  def approved?(key) when is_binary(key) and key != "", do: call({:approved?, key}, false)
  def approved?(_), do: false

  @doc "The requests waiting in the mailbox, oldest first."
  def pending, do: call(:pending, [])

  def approve(id), do: call({:decide, id, :approved}, {:error, :gone})
  def refuse(id), do: call({:decide, id, :refused}, {:error, :gone})

  @doc "The approved devices, newest first."
  def list, do: call(:list, [])

  @doc "Removes an approved device, which signs it out at once."
  def remove(id), do: call({:remove, id}, {:error, :gone})

  # When the board runs without this process (a test, or a start that
  # failed), nobody is approved and nothing waits.
  defp call(message, otherwise) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _ -> otherwise
  end

  # -- Server --

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    limits = Map.merge(@limits, Map.new(Keyword.get(opts, :limits, [])))
    Process.send_after(self(), :sweep, 5_000)

    {:ok,
     %{
       dir: dir,
       limits: limits,
       devices: read!(dir),
       requests: %{},
       window: %{since: now(), starts: %{}, all: 0}
     }}
  end

  @impl true
  def handle_call({:ask, address, agent}, _from, s) do
    s = s |> prune() |> roll()
    waiting = for {_, r} <- s.requests, r.state == :pending, do: r

    # Every ask gets a request of its own, never another browser's: the
    # browser that made one keeps its id in its cookie, and whoever holds
    # that id is who collects the approval. Several browsers can share an
    # address (behind a router, or a proxy on this machine).
    cond do
      Enum.count(waiting, &(&1.address == address)) >= s.limits.max_per_address ->
        {:reply, {:error, :busy}, s}

      length(waiting) >= s.limits.max_pending ->
        {:reply, {:error, :busy}, s}

      Map.get(s.window.starts, address, 0) >= s.limits.starts_per_minute ->
        {:reply, {:error, :busy}, s}

      s.window.all >= s.limits.starts_per_minute_all ->
        {:reply, {:error, :busy}, s}

      true ->
        id = random(16)
        code = code()
        t = now()

        r = %{
          id: id,
          code: code,
          address: address,
          name: device_name(agent),
          state: :pending,
          made: t,
          seen: t
        }

        Logger.info("Devices: #{r.name} at #{address} asks to open the board, code #{code}.")
        w = s.window

        w = %{
          w
          | starts: Map.update(w.starts, address, 1, &(&1 + 1)),
            all: w.all + 1
        }

        changed()
        {:reply, {:ok, id, code}, %{s | requests: Map.put(s.requests, id, r), window: w}}
    end
  end

  def handle_call({:status, id, address}, _from, s) do
    s = prune(s)

    case s.requests[id] do
      # Only the address that asked may collect the answer.
      %{address: ^address, state: :pending} = r ->
        {:reply, {:pending, r.code}, touch(s, id)}

      %{address: ^address, state: :approved} = r ->
        key = random(32)

        device = %{
          "id" => random(8),
          "hash" => hash(key),
          "name" => r.name,
          "address" => address,
          "approved_at" => System.os_time(:second),
          "seen_at" => System.os_time(:second)
        }

        devices = [device | s.devices]

        case write(s.dir, devices) do
          :ok ->
            Logger.info("Devices: #{r.name} at #{address} opened the board.")
            broadcast()

            # Kept until the request runs out, so a second tab or a reload
            # that asks at the same moment gets the same key, not a new code.
            {:reply, {:approved, key},
             %{
               s
               | devices: devices,
                 requests: Map.put(s.requests, id, Map.merge(r, %{state: :collected, key: key}))
             }}

          {:error, reason} ->
            Logger.warning("Devices: could not save the approved device: #{inspect(reason)}")
            {:reply, {:pending, r.code}, s}
        end

      %{address: ^address, state: :collected, key: key} ->
        {:reply, {:approved, key}, s}

      %{address: ^address, state: :refused} ->
        {:reply, :refused, %{s | requests: Map.delete(s.requests, id)}}

      _ ->
        {:reply, :gone, s}
    end
  end

  def handle_call({:approved?, key}, _from, s) do
    h = hash(key)

    case Enum.find(s.devices, &Plug.Crypto.secure_compare(&1["hash"], h)) do
      nil -> {:reply, false, s}
      device -> {:reply, true, seen(s, device)}
    end
  end

  def handle_call(:pending, _from, s) do
    s = prune(s)

    items =
      for {_, %{state: :pending} = r} <- s.requests do
        Map.take(r, [:id, :code, :name, :address, :made])
      end
      |> Enum.sort_by(&{&1.made, &1.id})

    {:reply, items, s}
  end

  def handle_call({:decide, id, state}, _from, s) do
    s = prune(s)

    case s.requests[id] do
      %{state: :pending} = r ->
        Logger.info("Devices: #{r.name} at #{r.address} was #{state}.")
        # Its ten minutes start again, so the browser finds the answer
        # however late it came.
        s = put_in(s.requests[id], %{r | state: state, made: now(), seen: now()})
        changed()
        {:reply, :ok, s}

      _ ->
        {:reply, {:error, :gone}, s}
    end
  end

  def handle_call(:list, _from, s) do
    list =
      for d <- s.devices do
        %{
          id: d["id"],
          name: d["name"],
          address: d["address"],
          approved_at: d["approved_at"],
          seen_at: d["seen_at"]
        }
      end

    {:reply, list, s}
  end

  def handle_call({:remove, id}, _from, s) do
    case Enum.split_with(s.devices, &(&1["id"] == id)) do
      {[], _} ->
        {:reply, {:error, :gone}, s}

      {[d], rest} ->
        case write(s.dir, rest) do
          :ok ->
            Logger.info("Devices: #{d["name"]} at #{d["address"]} was removed.")
            broadcast()
            {:reply, :ok, %{s | devices: rest}}

          error ->
            {:reply, error, s}
        end
    end
  end

  # A crash report shows the state: never a device's key in it.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{requests: requests} = s ->
        %{s | requests: Map.new(requests, fn {id, r} -> {id, Map.delete(r, :key)} end)}

      other ->
        other
    end)
  end

  @impl true
  def handle_info(:sweep, s) do
    Process.send_after(self(), :sweep, 5_000)
    {:noreply, prune(s)}
  end

  # -- Helpers --

  defp touch(s, id), do: update_in(s.requests[id], &%{&1 | seen: now()})

  # Last seen, kept to the hour, so a board open all day writes the file
  # once an hour, not on every page.
  defp seen(s, device) do
    at = System.os_time(:second)

    if at - (device["seen_at"] || 0) >= div(s.limits.seen_ms, 1000) do
      devices =
        Enum.map(s.devices, fn d ->
          if d["id"] == device["id"], do: Map.put(d, "seen_at", at), else: d
        end)

      case write(s.dir, devices) do
        :ok -> %{s | devices: devices}
        _ -> s
      end
    else
      s
    end
  end

  # Forgets what ran out, and says so when the mailbox lost an item.
  defp prune(s) do
    t = now()

    {keep, drop} =
      Enum.split_with(s.requests, fn {_, r} ->
        t - r.made < s.limits.expire_ms and
          not (r.state == :pending and t - r.seen >= s.limits.gone_ms)
      end)

    if Enum.any?(drop, fn {_, r} -> r.state == :pending end), do: changed()
    %{s | requests: Map.new(keep)}
  end

  # A new minute starts every count from nothing.
  defp roll(s) do
    if now() - s.window.since >= 60_000,
      do: %{s | window: %{since: now(), starts: %{}, all: 0}},
      else: s
  end

  defp changed, do: Wallboard.Mailbox.changed()

  defp broadcast do
    Phoenix.PubSub.broadcast(Wallboard.PubSub, @topic, {:devices, :changed})
    changed()
  end

  @doc false
  def code do
    n = :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned() |> rem(1_000_000)
    digits = n |> Integer.to_string() |> String.pad_leading(6, "0")
    String.slice(digits, 0, 3) <> "-" <> String.slice(digits, 3, 3)
  end

  @doc """
  A short name for a browser from its User-Agent, like "iPad, Safari". Only
  for the mailbox and the list of devices: a browser may say anything here,
  so it is never trusted for more.
  """
  def device_name(agent) when is_binary(agent) do
    device =
      cond do
        agent =~ "iPad" -> "iPad"
        agent =~ "iPhone" -> "iPhone"
        agent =~ "Android" -> "Android"
        agent =~ "Macintosh" -> "Mac"
        agent =~ "Windows" -> "Windows"
        agent =~ "CrOS" -> "Chromebook"
        agent =~ "Linux" -> "Linux"
        true -> "A device"
      end

    browser =
      cond do
        agent =~ "Edg/" -> "Edge"
        agent =~ "Firefox/" or agent =~ "FxiOS" -> "Firefox"
        agent =~ "Chrome/" or agent =~ "CriOS" -> "Chrome"
        agent =~ "Safari/" -> "Safari"
        true -> nil
      end

    if browser, do: device <> ", " <> browser, else: device
  end

  def device_name(_), do: "A device"

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp hash(key), do: :crypto.hash(:sha256, "vitalaize-device:" <> key) |> Base.encode16()

  defp now, do: System.monotonic_time(:millisecond)

  defp read!(dir) do
    file = Path.join(dir, "devices.json")

    with true <- File.exists?(file),
         {:ok, text} <- File.read(file),
         {:ok, list} when is_list(list) <- Jason.decode(text) do
      Enum.filter(list, &(is_map(&1) and is_binary(&1["hash"]) and is_binary(&1["id"])))
    else
      false ->
        []

      _ ->
        # Starting with nobody approved is the safe way to be wrong: each
        # device asks again.
        Logger.warning("Devices: #{file} cannot be read, so no device is approved until it is.")
        []
    end
  end

  # Written beside the file and moved over it, so a reader never sees half
  # a file, and never for a moment with wider permissions.
  defp write(dir, devices) do
    tmp = Path.join(dir, ".devices.json.#{System.unique_integer([:positive])}.tmp")
    File.write!(tmp, "")
    File.chmod!(tmp, 0o600)
    File.write!(tmp, Jason.encode!(devices))
    File.rename!(tmp, Path.join(dir, "devices.json"))
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  The key that signs the browsers' session cookies: made at random the
  first time and kept in `dir`, readable by this user only, so it stays the
  same across restarts and differs on every board.
  """
  def cookie_key!(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    file = Path.join(dir, "cookie_key")

    case File.read(file) do
      {:ok, key} when byte_size(key) >= 64 ->
        key

      found ->
        if match?({:ok, _}, found),
          do:
            Logger.warning(
              "Devices: #{file} was too short, so a new one is made. Each device needs approving again."
            )

        key = :crypto.strong_rand_bytes(64) |> Base.encode64()
        tmp = file <> ".#{System.unique_integer([:positive])}.tmp"
        File.write!(tmp, "")
        File.chmod!(tmp, 0o600)
        File.write!(tmp, key)
        File.rename!(tmp, file)
        key
    end
  end
end
