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
    2. The hub answers with its authority's certificate and a fingerprint
       of a random number of its own (`hub_commit/1`), not the number.
    3. The collector sends its number. The hub checks it against the
       fingerprint, puts the request in the mailbox, and only then answers
       with its own number, which the collector checks the same way.

  Each end works the code out (`code/5`) from the collector's key and name,
  the hub's authority and both random numbers, as it saw them. Someone in
  the middle who swaps the collector's key, or the hub's authority, makes
  the two ends see different things, so the codes differ. They cannot pick
  a key that gives a matching code either: each end is bound to its own
  number before it learns the other's, and the hub shows its number only
  once the request is in the mailbox. So nobody can work out the hub's
  code for a request and quietly drop it when it does not match: every
  try is one blind guess in a million, it is a request the owner sees
  with a code that matches nothing, and it holds that machine name's one
  place until the owner refuses it or it runs out.

  ## Limits

  The numbers are in `limits/0`. A request lasts ten minutes. The mailbox
  holds five requests at most, one per network address and one per machine
  name (never the hub's own), so nobody can flood it. A request that never sends its number is
  dropped after half a minute, and one whose machine stopped asking for
  the answer, after a minute (so a pairing given up with Ctrl-C frees its
  place by itself). That minute is also what a wrong guess costs someone
  in the middle: a request with the wrong code sits in the mailbox for at
  least a minute under that machine's name, so in the ten minutes a
  collector's code lasts they get about ten blind guesses under that name
  (and as many again under each look-alike name they care to show the
  owner), each one in a million. Each address may start six requests a
  minute and make 240 calls a minute; the door takes sixty new requests a
  minute in all. A request body over 4 KB is refused. The door takes these
  three calls, and the check below, and nothing else: no session data goes
  through it.

  ## A machine removed while it was away

  The link refuses a removed machine in its TLS handshake, which tells the
  machine only that the handshake failed. So a machine whose tries keep
  failing asks the door (`check/2`) whether its certificate still works.
  The door answers only a machine that signs its challenge with the
  certificate's key, so nobody else learns which machines are approved,
  and a challenge lasts a minute. The answer carries the serial number and
  the hub's signature, and the collector believes "removed" only with a
  signature from a hub certificate of its own hub's authority. Anyone on
  the network sees the answer, as they see the rest of the door's plain
  HTTP, but cannot fake one.

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
    # A request nobody has asked about for this long leaves the mailbox:
    # its machine has gone. A waiting collector asks every two seconds.
    gone_ms: 60_000,
    # Requests the mailbox shows at once.
    max_pending: 5,
    # Requests still at step 2, on top of those.
    max_opening: 10,
    starts_per_minute: 6,
    calls_per_minute: 240,
    starts_per_minute_all: 60,
    max_body_bytes: 4_096,
    # How long a challenge for `check/2` may be answered.
    check_ms: 60_000
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
  The fingerprint the hub sends before its random number: it binds the hub
  to that number without showing it.
  """
  def hub_commit(nonce) when is_binary(nonce),
    do: :crypto.hash(:sha256, framed(["vitalaize-pair-hub-1", nonce]))

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

  @doc """
  What a collector signs to ask the door whether its certificate still
  works (`check/2`): the hub's challenge and the certificate itself.
  """
  def check_text(challenge, cert_der) when is_binary(challenge) and is_binary(cert_der),
    do: framed(["vitalaize-pair-check-1", challenge, cert_der])

  @doc """
  What the hub signs in answer: the challenge, the certificate's serial
  number, and `"approved"` or `"removed"`.
  """
  def answer_text(challenge, serial, answer)
      when is_binary(challenge) and is_binary(serial) and is_binary(answer),
      do: framed(["vitalaize-pair-answer-1", challenge, serial, answer])

  # Each part with its length in front, so two different lists of parts can
  # never run together into the same bytes.
  defp framed(parts), do: for(p <- parts, into: <<>>, do: <<byte_size(p)::32, p::binary>>)

  @doc """
  A name for this machine that a certificate can carry: what `hostname`
  prints, with anything a name may not hold turned into a dash.
  VITALAIZE_MACHINE names it instead, for a script that sets up several
  machines on one computer.
  """
  def machine_name do
    {:ok, host} = :inet.gethostname()

    name =
      case System.get_env("VITALAIZE_MACHINE") do
        named when is_binary(named) and named != "" -> named
        _ -> to_string(host)
      end
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
    * `{:error, :hub_failed}`: approved, but the hub could not make the
      certificate; nothing was saved
    * `{:error, :busy}`: the hub's mailbox is full, this machine already
      has a request waiting, or it asked too often; try again in a while
    * `{:error, :bad_name}`: the hub cannot put this name in a certificate
    * `{:error, :name_taken}`: the hub itself has this machine's name
    * `{:error, :not_a_hub}`: the address answers, but pairing is not on there
    * `{:error, {:folder, reason}}`: `dir` cannot be written. Nothing was
      asked of the hub, unless the folder failed only at the very end.
    * `{:error, {:hub, reason}}`: the hub did not answer, or answered
      something that makes no sense
  """
  def pair(opts) do
    name = opts[:name] || machine_name()
    dir = Keyword.fetch!(opts, :dir)
    poll_ms = opts[:poll_ms] || 2_000
    on_code = opts[:on_code] || fn _ -> :ok end

    with {:ok, hub} <- address(Keyword.fetch!(opts, :hub)),
         true <- Authority.machine_name?(name) || {:error, :bad_name},
         # Before anything is asked: a certificate the hub made and this
         # machine could not save would be worse than none.
         :ok <- writable(dir) do
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
           {:ok, shown} <-
             call(hub, "confirm", %{id: opened.id, nonce: Base.encode16(nonce, case: :lower)}),
           {:ok, hub_nonce} <- hub_nonce(shown, opened.hub_commit) do
        code = code(key_bytes, name, opened.ca_bytes, nonce, hub_nonce)
        on_code.(%{code: code, hub: opened.hub, machine: name, expires_in: opened.expires_in})
        deadline = now() + opened.expires_in * 1000 + poll_ms

        with {:ok, cert_pem} <- wait(hub, opened.id, poll_ms, deadline),
             true <-
               Authority.issued_for?(cert_pem, opened.ca_pem, name, public_pem) ||
                 {:error, {:hub, "the certificate is not for this machine's key"}} do
          files = [
            {"key.pem", key_pem},
            {"ca.pem", opened.ca_pem},
            # `port` is the board's own, where the door is (`check/2`).
            {"hub.json",
             Jason.encode!(%{
               host: hub.host,
               port: hub.port,
               link_port: opened.link_port,
               machine: name
             })},
            # Last: `load/1` takes the folder as paired only with all four,
            # and a certificate must never sit beside an older key.
            {"cert.pem", cert_pem}
          ]

          with :ok <- save(dir, files), do: {:ok, %{dir: dir, machine: name, code: code}}
        end
      end
    end
  end

  # What the hub's first answer must hold. A hub is not trusted yet, so
  # every part is checked for its shape before it is used.
  defp opened(%{"id" => id, "commit" => commit, "ca" => ca_pem} = reply)
       when is_binary(id) and byte_size(id) <= 64 and is_binary(commit) and is_binary(ca_pem) do
    with {:ok, <<_::binary-size(32)>> = hub_commit} <- Base.decode16(commit, case: :mixed),
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
         hub_commit: hub_commit,
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

  # The hub's number, shown once the request is in its mailbox. It must be
  # the one the hub bound itself to at the start.
  defp hub_nonce(%{"nonce" => nonce}, hub_commit) when is_binary(nonce) do
    with {:ok, <<_::binary-size(32)>> = hub_nonce} <- Base.decode16(nonce, case: :mixed),
         true <- Plug.Crypto.secure_compare(hub_commit(hub_nonce), hub_commit) do
      {:ok, hub_nonce}
    else
      _ -> {:error, {:hub, "the hub changed its number on the way"}}
    end
  end

  defp hub_nonce(_, _), do: {:error, {:hub, "the hub's answer could not be read"}}

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

      {:ok, %{"state" => "failed"}} ->
        {:error, :hub_failed}

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

  @doc """
  Asks the hub's pairing door whether this machine's certificate still
  works. The link's client asks when its tries keep failing: the TLS
  handshake refuses a revoked certificate, and says only that it failed,
  not why.

  `door` is the board's address, `%{host, port}`. `tls` holds the
  `cert_pem`, `key_pem` and `ca_pem` pairing saved. The door gives a
  challenge, and this machine signs it with its key, so the door answers
  only the machine that holds the certificate.

  `{:ok, :removed}` only when the hub said so and signed it with a hub
  certificate from the authority in `ca_pem`: someone on the network
  cannot switch a collector off by answering in the hub's place.
  `{:ok, :approved}` while the hub still takes the certificate, and
  `{:error, reason}` when there is no answer to believe.
  """
  def check(door, %{cert_pem: cert_pem, key_pem: key_pem, ca_pem: ca_pem}) do
    with {:ok, cert_der} <- Authority.cert_bytes(cert_pem),
         {:ok, serial} <- Authority.serial(cert_der),
         {:ok, %{"challenge" => hex}} when is_binary(hex) <- call(door, "check", %{}),
         {:ok, challenge} when byte_size(challenge) in 1..256 <- Base.decode16(hex, case: :mixed) do
      proof = Authority.prove(key_pem, check_text(challenge, cert_der))
      asked = %{challenge: hex, cert: cert_pem, proof: Base.encode16(proof, case: :lower)}

      with {:ok, reply} <- call(door, "check", asked),
           do: answered(reply, ca_pem, challenge, serial)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:hub, "the hub's answer could not be read"}}
    end
  end

  # Believed only with the hub's signature over this very challenge and
  # this certificate's serial number.
  defp answered(
         %{"answer" => answer, "signature" => hex, "hub" => hub_pem},
         ca_pem,
         challenge,
         serial
       )
       when answer in ["approved", "removed"] and is_binary(hex) and is_binary(hub_pem) do
    with {:ok, signature} <- Base.decode16(hex, case: :mixed),
         true <-
           Authority.hub_signed?(
             ca_pem,
             hub_pem,
             answer_text(challenge, serial, answer),
             signature
           ) do
      {:ok, if(answer == "removed", do: :removed, else: :approved)}
    else
      _ -> {:error, {:hub, "the answer is not signed by this machine's hub"}}
    end
  end

  defp answered(_reply, _ca_pem, _challenge, _serial),
    do: {:error, {:hub, "the hub's answer could not be read"}}

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
          {:ok, %{"error" => "name_taken"}} -> {:error, :name_taken}
          _ -> {:error, {:hub, "the hub refused the request"}}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:hub, "the hub answered #{status}"}}

      {:error, reason} ->
        {:error, {:hub, unreachable(reason, "http://#{host}:#{hub.port}")}}
    end
  end

  # The folder, made and tried out with a file of its own.
  defp writable(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    probe = Path.join(dir, ".probe.#{System.unique_integer([:positive])}.tmp")
    File.write!(probe, "")
    File.rm!(probe)
    :ok
  rescue
    e in [File.Error, File.RenameError] ->
      {:error, {:folder, "#{dir}: #{:file.format_error(e.reason)}"}}
  end

  # A folder only this user can read. Each file is written beside its
  # place and moved over it, so it is never there half written or, for a
  # moment, readable by others. The certificate of an earlier pairing goes
  # first, so the folder never holds a certificate and a key that do not
  # belong together.
  defp save(dir, files) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    File.rm(Path.join(dir, "cert.pem"))

    for {name, text} <- files do
      tmp = Path.join(dir, ".#{name}.#{System.unique_integer([:positive])}.tmp")
      File.write!(tmp, "")
      File.chmod!(tmp, 0o600)
      File.write!(tmp, text)
      File.rename!(tmp, Path.join(dir, name))
    end

    :ok
  rescue
    e in [File.Error, File.RenameError] ->
      # Nothing half done stays behind, least of all a copy of the key.
      for file <- Path.wildcard(Path.join(dir, ".*.tmp"), match_dot: true), do: File.rm(file)
      {:error, {:folder, "#{dir}: #{:file.format_error(e.reason)}"}}
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

  # Why no answer came from an address, in words: what :httpc gives back
  # is for a programmer.
  defp unreachable(reason, address) do
    text = inspect(reason)

    cond do
      text =~ "econnrefused" ->
        "nothing answers at #{address}. Check the address, and that the hub is running."

      text =~ "nxdomain" ->
        "no machine by that name was found (#{address}). Check the address."

      text =~ "timeout" or text =~ "ehostunreach" or text =~ "enetunreach" ->
        "#{address} did not answer. Check the address, and that this machine and " <>
          "the hub are on the same network."

      true ->
        "#{address} could not be reached (#{String.slice(text, 0, 120)})."
    end
  end

  @doc "Why a pairing failed, as a sentence for the person who asked."
  def why(:refused),
    do: "The hub's owner refused this machine. Nothing changed here; ask them, then pair again."

  def why(:expired), do: "Nobody approved the code in time. Ask again for a new one."

  def why(:hub_failed),
    do:
      "The hub approved this machine but could not make the certificate. " <>
        "Look at the hub's log, then ask again."

  def why(:busy),
    do:
      "The hub has too many requests waiting, or one from this machine or under its name. " <>
        "Try again in a minute."

  def why(:bad_name),
    do: "Use letters, numbers, spaces, dots, - and _ for the machine's name, 63 at most."

  def why(:name_taken),
    do:
      "The hub has the same name as this machine (#{machine_name()}), and two machines " <>
        "cannot share one. Give this one another name (on a Mac: System Settings, General, " <>
        "Sharing, Local hostname), restart it, then pair again."

  def why(:not_a_hub),
    do:
      "That board does not take collectors. On the hub, open its settings, turn on Take collectors, and ask again."

  def why({:folder, reason}), do: "Could not save the certificate in #{reason}"
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
    |> one_per_host()
  end

  @doc false
  # One hub with two network cards answers once per card, under one host
  # name: it is one hub. Two hosts under one announced name are two, and
  # whoever asked is told so.
  def one_per_host(hubs) do
    hubs
    |> Enum.uniq_by(&{&1.name, &1.port, &1[:as] || &1.host})
    |> Enum.map(&Map.delete(&1, :as))
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
        do: printable(name)
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
        ["=", _if, "IPv4", name, _type, _domain, host, address, port | _] <-
          [String.split(line, ";")],
        {port, ""} <- [Integer.parse(port)],
        uniq: true,
        do: %{name: unescape(name), host: address, port: port, as: printable(host)}
  end

  # avahi writes a space in a name as \032 (its decimal code). A name
  # comes from whoever announces it, and it is printed in a terminal, so
  # nothing that is not plain text survives.
  defp unescape(name) do
    ~r/\\(\d{3})/
    |> Regex.replace(name, fn _, code -> <<String.to_integer(code)::utf8>> end)
    |> printable()
  end

  defp printable(text) do
    if String.valid?(text),
      do: text |> String.replace(~r/[\p{C}]/u, "") |> String.slice(0, 80),
      else: ""
  end
end
