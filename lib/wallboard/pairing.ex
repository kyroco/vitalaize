defmodule Wallboard.Pairing do
  @moduledoc """
  Pairing: how a new collector gets its certificate from the hub (see
  `Wallboard.Link`), with nothing secret typed or pasted.

  It works like pairing a Bluetooth device. The collector makes its own key
  pair and asks the hub to pair. Both ends then show the same short code,
  such as 482-913. The owner reads the code on the collector, finds the
  same code in the board's mailbox and taps Approve. The hub signs the
  collector's public key, and the collector saves its certificate and the
  hub's authority. The private key never leaves the collector.

  ## The parts

    * this module: what both ends share (how the code is worked out) and
      the collector's side, `pair/1`
    * `Wallboard.Pairing.Door`: the hub's side, the list of requests
    * `WallboardWeb.PairController`: the door itself, three small addresses
      on the board's own port
    * `Wallboard.Mailbox.NewMachine`: the mailbox item with Approve and Refuse

  ## The exchange

  The door is plain HTTP on the local network, so anyone there can read and
  change what passes. Nothing in it is secret. What matters is that nobody
  can swap a key on the way without the two codes differing.

    1. The collector picks a secret random number and sends its name, its
       public key and a fingerprint of the three together (`commit/3`).
       The fingerprint ties it to that number without showing it.
    2. The hub answers with its authority's certificate and a random number
       of its own.
    3. The collector sends its number. The hub checks it against the
       fingerprint. Only now does the request appear in the mailbox.

  Each end works the code out (`code/5`) from the collector's key and name,
  the hub's authority and both random numbers, as it saw them. Someone in
  the middle who swaps the collector's key, or the hub's authority, makes
  the two ends see different things, so the codes differ. They cannot pick
  a key that gives a matching code either: each end is bound to its own
  number before it learns the other's, so every try is one blind guess in
  a million, and each wrong guess is a request the owner sees with a code
  that matches nothing.

  ## Limits

  The numbers are in `limits/0`. A request lasts ten minutes. The mailbox
  holds five requests at most, one per network address and one per machine
  name, so nobody can flood it. A request that never sends its number is
  dropped after half a minute. Each address may start six requests a
  minute and make 240 calls a minute; the door takes sixty new requests a
  minute in all. A request body over 4 KB is refused. The door takes these
  three calls and nothing else: no session data goes through it.

  ## Where "safe enough" ends

  This defends against anyone on the local network who holds no approved
  certificate: they get none without the owner tapping Approve on a code
  that matches, and they cannot fill the mailbox. They can keep the door's
  five places busy, which delays a real pairing and shows the owner
  requests with unknown codes; refusing those frees the places.

  It does not defend a collector against something on the network posing
  as the hub from the start. That impostor can "approve" the collector
  itself and receive what the collector then sends. The owner's check is
  the mailbox: a code on the collector that never shows up there means the
  collector is talking to something else. It also does not defend against
  someone with admin access to the hub's own machine, or someone who holds
  the board password.
  """

  alias Wallboard.Link.Authority

  @limits %{
    # How long a request waits for Approve or Refuse.
    expire_ms: 600_000,
    # How long a request may take to send its number (step 3).
    confirm_ms: 30_000,
    # Requests the mailbox shows at once.
    max_pending: 5,
    # Requests still at step 2, on top of those.
    max_opening: 10,
    starts_per_minute: 6,
    calls_per_minute: 240,
    starts_per_minute_all: 60,
    max_body_bytes: 4_096
  }

  @doc "The door's limits."
  def limits, do: @limits

  @doc """
  The fingerprint a collector sends before its random number: it binds the
  collector to that number, its key and its name without showing the number.
  """
  def commit(nonce, key_bytes, name)
      when is_binary(nonce) and is_binary(key_bytes) and is_binary(name) do
    :crypto.hash(:sha256, framed(["vitalaize-pair-commit-1", nonce, key_bytes, name]))
  end

  @doc """
  The code both ends show, like `"482-913"`: six digits from the collector's
  key and name, the hub's authority certificate and both random numbers.
  """
  def code(key_bytes, name, ca_bytes, collector_nonce, hub_nonce) do
    <<n::64, _::binary>> =
      :crypto.hash(
        :sha256,
        framed(["vitalaize-pair-code-1", key_bytes, name, ca_bytes, collector_nonce, hub_nonce])
      )

    digits = n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    String.slice(digits, 0, 3) <> "-" <> String.slice(digits, 3, 3)
  end

  # Each part with its length in front, so two different lists of parts can
  # never run together into the same bytes.
  defp framed(parts), do: for(p <- parts, into: <<>>, do: <<byte_size(p)::32, p::binary>>)

  @doc """
  A name for this machine that a certificate can carry: what `hostname`
  prints, with anything a name may not hold turned into a dash.
  """
  def machine_name do
    {:ok, host} = :inet.gethostname()

    name =
      host
      |> to_string()
      |> String.replace_suffix(".local", "")
      |> String.replace(~r/[^A-Za-z0-9 ._-]/, "-")
      |> String.slice(0, 63)
      |> String.replace(~r/\A[^A-Za-z0-9]+|[^A-Za-z0-9]+\z/, "")

    if Authority.machine_name?(name), do: name, else: "collector"
  end

  @doc "Where a collector keeps what pairing gave it, for these settings."
  def dir(settings) do
    settings
    |> get_in([:collector, :dir])
    |> Wallboard.Settings.collector_dir()
    |> Path.join("link")
  end

  @doc """
  What a paired collector holds in `dir`, ready for `Wallboard.Link.Client`:
  `{:ok, %{tls: %{cert_pem, key_pem, ca_pem}, host, port, machine}}`, or
  `:error` when it has not paired (or the files cannot be read).
  """
  def load(dir) do
    with {:ok, cert} <- File.read(Path.join(dir, "cert.pem")),
         {:ok, key} <- File.read(Path.join(dir, "key.pem")),
         {:ok, ca} <- File.read(Path.join(dir, "ca.pem")),
         {:ok, text} <- File.read(Path.join(dir, "hub.json")),
         {:ok, %{"host" => host, "link_port" => port, "machine" => machine}}
         when is_binary(host) and is_integer(port) and is_binary(machine) <- Jason.decode(text) do
      {:ok,
       %{
         tls: %{cert_pem: cert, key_pem: key, ca_pem: ca},
         host: host,
         port: port,
         machine: machine
       }}
    else
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # The collector's side

  @doc """
  Pairs this machine with a hub and saves what it gets. This is the function
  `vitalaize setup` and the Mac app call.

  Options:

    * `hub` (required): the board's address, like `"http://192.168.1.20:4747"`
      or `"192.168.1.20"` (port 4747 unless given). `discover/1` finds it.
    * `dir` (required): where to save `key.pem`, `cert.pem`, `ca.pem` and
      `hub.json`, in a folder only this user can read.
    * `name`: this machine's name. `machine_name/0` unless given.
    * `on_code`: called once with `%{code, hub, machine, expires_in}` when
      there is a code to show. `expires_in` is in seconds.
    * `poll_ms`: how often to ask the hub for the answer. 2 seconds.

  It returns when the owner has decided or the request ran out:

    * `{:ok, %{dir, machine, code}}`: approved, and the files are saved
    * `{:error, :refused}`, `{:error, :expired}`
    * `{:error, :busy}`: the hub's mailbox is full, this machine already
      has a request waiting, or it asked too often; try again in a while
    * `{:error, :bad_name}`: the hub cannot put this name in a certificate
    * `{:error, :not_a_hub}`: the address answers, but pairing is not on there
    * `{:error, {:hub, reason}}`: the hub did not answer, or answered
      something that makes no sense
  """
  def pair(opts) do
    name = opts[:name] || machine_name()
    dir = Keyword.fetch!(opts, :dir)
    poll_ms = opts[:poll_ms] || 2_000
    on_code = opts[:on_code] || fn _ -> :ok end

    with {:ok, hub} <- address(Keyword.fetch!(opts, :hub)),
         true <- Authority.machine_name?(name) || {:error, :bad_name} do
      %{key_pem: key_pem, public_pem: public_pem} = Authority.new_key_pair()
      {:ok, key_bytes} = Authority.public_bytes(public_pem)
      nonce = :crypto.strong_rand_bytes(32)

      start = %{
        name: name,
        key: public_pem,
        commit: Base.encode16(commit(nonce, key_bytes, name), case: :lower)
      }

      with {:ok, reply} <- call(hub, "start", start),
           {:ok, opened} <- opened(reply),
           code = code(key_bytes, name, opened.ca_bytes, nonce, opened.nonce),
           {:ok, _} <-
             call(hub, "confirm", %{id: opened.id, nonce: Base.encode16(nonce, case: :lower)}) do
        on_code.(%{code: code, hub: opened.hub, machine: name, expires_in: opened.expires_in})
        deadline = now() + opened.expires_in * 1000 + poll_ms

        with {:ok, cert_pem} <- wait(hub, opened.id, poll_ms, deadline),
             true <-
               Authority.issued_for?(cert_pem, opened.ca_pem, name, public_pem) ||
                 {:error, {:hub, "the certificate is not for this machine's key"}} do
          save!(dir, %{
            "key.pem" => key_pem,
            "cert.pem" => cert_pem,
            "ca.pem" => opened.ca_pem,
            "hub.json" =>
              Jason.encode!(%{host: hub.host, link_port: opened.link_port, machine: name})
          })

          {:ok, %{dir: dir, machine: name, code: code}}
        end
      end
    end
  end

  # What the hub's first answer must hold. A hub is not trusted yet, so
  # every part is checked for its shape before it is used.
  defp opened(%{"id" => id, "nonce" => nonce, "ca" => ca_pem} = reply)
       when is_binary(id) and byte_size(id) <= 64 and is_binary(nonce) and is_binary(ca_pem) do
    with {:ok, <<_::binary-size(32)>> = hub_nonce} <- Base.decode16(nonce, case: :mixed),
         {:ok, ca_bytes} <- Authority.cert_bytes(ca_pem),
         port when is_integer(port) and port > 0 and port < 65_536 <- reply["link_port"] do
      expires_in =
        case reply["expires_in"] do
          n when is_integer(n) and n > 0 -> min(n, div(@limits.expire_ms, 1000))
          _ -> div(@limits.expire_ms, 1000)
        end

      {:ok,
       %{
         id: id,
         nonce: hub_nonce,
         ca_pem: ca_pem,
         ca_bytes: ca_bytes,
         link_port: port,
         expires_in: expires_in,
         hub: clean_label(reply["hub"])
       }}
    else
      _ -> {:error, {:hub, "the hub's answer could not be read"}}
    end
  end

  defp opened(_), do: {:error, {:hub, "the hub's answer could not be read"}}

  # The hub's own name, for the line "Connect to ...". Only shown.
  defp clean_label(label) when is_binary(label) do
    if String.valid?(label) do
      label |> String.replace(~r/[^\p{L}\p{N} ._'-]/u, "") |> String.slice(0, 63)
    else
      ""
    end
  end

  defp clean_label(_), do: ""

  defp wait(hub, id, poll_ms, deadline) do
    case call(hub, "wait", %{id: id}) do
      {:ok, %{"state" => "approved", "cert" => cert}} when is_binary(cert) ->
        {:ok, cert}

      {:ok, %{"state" => "refused"}} ->
        {:error, :refused}

      {:ok, %{"state" => "waiting"}} ->
        if now() >= deadline do
          {:error, :expired}
        else
          Process.sleep(poll_ms)
          wait(hub, id, poll_ms, deadline)
        end

      # The hub no longer knows the request: it ran out.
      {:error, :gone} ->
        {:error, :expired}

      # A hub that is restarting, or a call too many: keep asking until
      # the request's own time is up.
      {:error, reason} when reason == :busy or (is_tuple(reason) and elem(reason, 0) == :hub) ->
        if now() >= deadline do
          {:error, :expired}
        else
          Process.sleep(poll_ms)
          wait(hub, id, poll_ms, deadline)
        end

      {:ok, _} ->
        {:error, {:hub, "the hub's answer could not be read"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # "192.168.1.20", "192.168.1.20:4747" or "http://192.168.1.20:4747".
  defp address(text) when is_binary(text) do
    text = String.trim(text)
    uri = URI.parse(if String.contains?(text, "://"), do: text, else: "http://" <> text)

    if uri.scheme == "http" and is_binary(uri.host) and uri.host != "" and
         uri.host =~ ~r/\A[A-Za-z0-9.:_-]+\z/ do
      # With no port in the text, the board's usual one.
      port = if Regex.match?(~r/:\d+(\/.*)?\z/, text), do: uri.port, else: 4747
      {:ok, %{host: uri.host, port: port}}
    else
      {:error, {:hub, "that is not a board's address"}}
    end
  end

  defp address(_), do: {:error, {:hub, "that is not a board's address"}}

  defp call(hub, step, body) do
    host = if String.contains?(hub.host, ":"), do: "[#{hub.host}]", else: hub.host
    url = String.to_charlist("http://#{host}:#{hub.port}/pair/#{step}")
    request = {url, [], ~c"application/json", Jason.encode!(body)}

    case :httpc.request(
           :post,
           request,
           [timeout: 10_000, connect_timeout: 5_000, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, text}} ->
        case Jason.decode(text) do
          {:ok, %{} = reply} -> {:ok, reply}
          _ -> {:error, {:hub, "the hub's answer could not be read"}}
        end

      {:ok, {{_, 429, _}, _, _}} ->
        {:error, :busy}

      {:ok, {{_, 404, _}, _, text}} ->
        # The door's own "no such request", or an address with no door.
        if match?({:ok, %{"error" => "gone"}}, Jason.decode(text)),
          do: {:error, :gone},
          else: {:error, :not_a_hub}

      {:ok, {{_, 422, _}, _, text}} ->
        case Jason.decode(text) do
          {:ok, %{"error" => "bad_name"}} -> {:error, :bad_name}
          _ -> {:error, {:hub, "the hub refused the request"}}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:hub, "the hub answered #{status}"}}

      {:error, reason} ->
        {:error, {:hub, reason |> inspect() |> String.slice(0, 200)}}
    end
  end

  # A folder only this user can read. Each file is written beside its
  # place and moved over it, so it is never there half written or, for a
  # moment, readable by others.
  defp save!(dir, files) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    for {name, text} <- files do
      tmp = Path.join(dir, ".#{name}.#{System.unique_integer([:positive])}.tmp")
      File.write!(tmp, "")
      File.chmod!(tmp, 0o600)
      File.write!(tmp, text)
      File.rename!(tmp, Path.join(dir, name))
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # The plain command

  @doc """
  Pairs from a terminal: prints the code, waits for the owner, and says how
  it ended. `hub` is the board's address, or nil to look for one on the
  local network. Options: `name`, and `dir` (the collector's folder from
  settings unless given). Returns `:ok`, or `{:error, message}` with a
  sentence for the person at the terminal.
  """
  def run(hub \\ nil, opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:inets)
    dir = opts[:dir] || dir(Wallboard.Settings.base())

    with {:ok, hub} <- if(hub, do: {:ok, hub}, else: found()) do
      case pair(hub: hub, dir: dir, name: opts[:name], on_code: &show/1) do
        {:ok, %{machine: machine}} ->
          IO.puts("Approved. #{machine}'s certificate is saved in #{dir}")
          :ok

        {:error, reason} ->
          {:error, why(reason)}
      end
    end
  end

  defp found do
    IO.puts("Looking for a hub on this network...")

    case discover() do
      [%{host: host, port: port, name: name}] ->
        IO.puts("Found #{name}.")
        {:ok, "#{host}:#{port}"}

      [] ->
        {:error, "No hub found on this network. Give the hub's address."}

      hubs ->
        {:error,
         "More than one hub answered. Give the address of one:\n" <>
           Enum.map_join(hubs, "\n", &"  #{&1.host}:#{&1.port}   (#{&1.name})")}
    end
  end

  defp show(%{code: code, hub: hub, expires_in: secs}) do
    IO.puts("""

        #{code}

    Open the mailbox on #{if hub == "", do: "the hub", else: hub}'s board and approve this code.
    It matches only this machine and expires in #{div(secs, 60)} minutes.
    Waiting for the hub to approve...
    """)
  end

  @doc "Why a pairing failed, as a sentence for the person who asked."
  def why(:refused), do: "The hub refused this machine."
  def why(:expired), do: "Nobody approved the code in time. Ask again for a new one."

  def why(:busy),
    do: "The hub has too many requests waiting, or one from this machine. Try again in a minute."

  def why(:bad_name),
    do: "Use letters, numbers, spaces, dots, - and _ for the machine's name, 63 at most."

  def why(:not_a_hub),
    do: "That board does not take collectors. Turn the link on in its settings (link.enabled)."

  def why({:hub, reason}), do: "Could not pair: #{reason}"
  def why(other), do: "Could not pair: #{inspect(other)}"

  # ---------------------------------------------------------------------------
  # Finding the hub

  @doc """
  Looks for boards announcing themselves on the local network (see
  `Wallboard.Advertise`) for about `wait_ms`. Returns
  `[%{name, host, port}]`, empty when none answered or this machine has no
  tool to look with (`dns-sd` on a Mac, `avahi-browse` on Linux).
  """
  def discover(wait_ms \\ 3_000) do
    cond do
      System.find_executable("dns-sd") || File.exists?("/usr/bin/dns-sd") ->
        for name <- wait_ms |> listen("dns-sd", ["-B", "_wallboard._tcp", "local"]) |> browsed(),
            hub <-
              wait_ms
              |> listen("dns-sd", ["-L", name, "_wallboard._tcp", "local"])
              |> resolved(name),
            do: hub

      System.find_executable("avahi-browse") ->
        wait_ms |> listen("avahi-browse", ["-rtp", "_wallboard._tcp"]) |> avahi()

      true ->
        []
    end
    |> Enum.uniq()
  end

  # `dns-sd` never stops by itself, so it runs under a small shell that
  # stops it after the wait. What it printed until then is the answer.
  defp listen(wait_ms, tool, args) do
    exe = System.find_executable(tool) || "/usr/bin/#{tool}"
    secs = Float.to_string(max(wait_ms, 100) / 1000)
    # The shell's own note that it stopped the tool goes nowhere either.
    script = ~s(exec 2>/dev/null; "$0" "$@" & p=$!; sleep "$WAIT"; kill $p; wait $p)

    case System.cmd("/bin/sh", ["-c", script, exe | args], env: [{"WAIT", secs}]) do
      {out, _} -> out
    end
  rescue
    _ -> ""
  end

  @doc false
  # The instance names in what `dns-sd -B` prints: the text after the
  # service type on each "Add" line.
  def browsed(out) do
    for line <- String.split(out, "\n"),
        [_, name] <- [Regex.run(~r/\sAdd\s.*?\s_wallboard\._tcp\.\s+(.+?)\s*\z/, line)],
        uniq: true,
        do: name
  end

  @doc false
  # "... can be reached at host.local.:4747 (interface 11)" from `dns-sd -L`.
  def resolved(out, name) do
    for line <- String.split(out, "\n"),
        [_, host, port] <- [Regex.run(~r/can be reached at (\S+?)\.?:(\d+)/, line)],
        uniq: true,
        do: %{name: name, host: host, port: String.to_integer(port)}
  end

  @doc false
  # `avahi-browse -rtp` prints one line per answer, fields apart by ";":
  # =;interface;protocol;name;type;domain;host;address;port;text
  def avahi(out) do
    for line <- String.split(out, "\n"),
        ["=", _if, "IPv4", name, _type, _domain, _host, address, port | _] <-
          [String.split(line, ";")],
        {port, ""} <- [Integer.parse(port)],
        uniq: true,
        do: %{name: unescape(name), host: address, port: port}
  end

  # avahi writes a space in a name as \032 (its decimal code).
  defp unescape(name) do
    Regex.replace(~r/\\(\d{3})/, name, fn _, code -> <<String.to_integer(code)::utf8>> end)
  end
end
