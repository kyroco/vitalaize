defmodule Wallboard.Link.Authority do
  @moduledoc """
  The hub's own small certificate authority: it decides which machines may
  open the link (see `Wallboard.Link`).

  It lives in one folder beside the database, readable only by its owner:

    * `ca.key` and `ca.pem`: the authority's own key and certificate. Every
      collector keeps a copy of `ca.pem` and trusts only a hub that proves
      it holds a certificate signed by it.
    * `hub.key` and `hub.pem`: the certificate the hub's link port serves.
    * `machines.json`: every machine certificate ever issued, by serial
      number, with when it was issued and when it was revoked.

  A machine's certificate carries the machine's name. That name, not
  anything a message says, is who the hub takes the machine to be. A
  certificate works only while `machines.json` lists its serial number as
  not revoked, so revoking takes effect on the next connect, and a
  certificate this folder does not know is refused even when it is signed.

  Certificates last ten years: a machine leaves by being revoked, not by a
  date nobody remembers.

  Whoever can read this folder can make certificates. It is protected the
  way the database is: by the file permissions of the hub's own machine.
  """

  require Record

  # Erlang's own certificate records, under names Elixir can call.
  for {name, record} <- [
        otp_certificate: :OTPCertificate,
        otp_tbs_certificate: :OTPTBSCertificate,
        otp_subject_public_key_info: :OTPSubjectPublicKeyInfo,
        public_key_algorithm: :PublicKeyAlgorithm,
        signature_algorithm: :SignatureAlgorithm,
        validity: :Validity,
        attribute_type_and_value: :AttributeTypeAndValue,
        extension: :Extension,
        basic_constraints: :BasicConstraints,
        ec_private_key: :ECPrivateKey,
        ec_point: :ECPoint
      ] do
    Record.defrecordp(
      name,
      record,
      Record.extract(record, from_lib: "public_key/include/public_key.hrl")
    )
  end

  # The name every hub certificate carries. A collector asks for it instead
  # of the hub's address, which changes with the network, so a machine's
  # certificate can never stand in for the hub's.
  @hub_name "hub.vitalaize.internal"

  @curve {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}
  @ec_public_key {1, 2, 840, 10_045, 2, 1}
  @ecdsa_sha256 {1, 2, 840, 10_045, 4, 3, 2}
  @common_name {2, 5, 4, 3}
  @basic_constraints {2, 5, 29, 19}
  @key_usage {2, 5, 29, 15}
  @ext_key_usage {2, 5, 29, 37}
  @subject_alt_name {2, 5, 29, 17}
  @server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @client_auth {1, 3, 6, 1, 5, 5, 7, 3, 2}

  @years 10
  @lock_wait_ms 5_000
  @lock_stale_s 30

  @doc "The name a collector asks the hub's certificate to carry."
  def hub_name, do: @hub_name

  @doc "Where the authority lives for these settings: a `link` folder beside the database."
  def dir(settings) do
    settings
    |> get_in([:archive, :path])
    |> Wallboard.Settings.db_path()
    |> Path.dirname()
    |> Path.join("link")
  end

  @doc """
  Makes the authority and the hub's certificate in `dir` when they are not
  there yet. Safe to call on every start.
  """
  def ensure!(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    locked(dir, fn ->
      unless File.regular?(path(dir, "ca.key")) and File.regular?(path(dir, "ca.pem")) do
        key = new_key()
        cert = sign(tbs("VitalAIze hub authority", public(key), :ca, nil), key)
        write!(dir, "ca.key", key_pem(key))
        write!(dir, "ca.pem", cert_pem(cert))
        # A new authority cannot vouch for an older one's certificates.
        File.rm(path(dir, "hub.key"))
        File.rm(path(dir, "hub.pem"))
      end

      unless File.regular?(path(dir, "hub.key")) and File.regular?(path(dir, "hub.pem")) do
        {ca_cert, ca_key} = ca!(dir)
        key = new_key()
        cert = sign(tbs("VitalAIze hub", public(key), :hub, ca_cert), ca_key)
        write!(dir, "hub.key", key_pem(key))
        write!(dir, "hub.pem", cert_pem(cert))
      end

      unless File.regular?(path(dir, "machines.json")), do: write_index!(dir, %{})
    end)

    :ok
  end

  @doc "The authority's certificate as PEM text: what a collector keeps to know its hub."
  def ca_pem(dir), do: File.read!(path(dir, "ca.pem"))

  @doc """
  Makes a key and a certificate for a machine. Returns `{:ok, files}` with
  `cert_pem`, `key_pem`, `ca_pem` and `serial`, or `{:error, reason}`.

  For tests and for setting one machine up by hand. Pairing
  (`Wallboard.Pairing`) uses `sign/4`, so a machine's key never leaves it.
  """
  def issue(dir, machine, opts \\ []) do
    key = new_key()

    with {:ok, signed} <- sign_public(dir, machine, public(key), opts) do
      {:ok, Map.put(signed, :key_pem, key_pem(key))}
    end
  end

  @doc false
  # For tests that issue a certificate before any hub has started.
  def issue_offline(dir, machine) do
    :ok = ensure!(dir)
    issue(dir, machine)
  end

  @doc """
  Signs a machine's own public key, given as PEM text. Returns `{:ok, files}`
  with `cert_pem`, `ca_pem` and `serial`.

  A name that already has a working certificate is refused with
  `{:error, :taken}`, unless `replace: true` revokes the older one.
  """
  def sign(dir, machine, public_key_pem, opts \\ []) when is_binary(public_key_pem) do
    with {:ok, point} <- read_public(public_key_pem) do
      sign_public(dir, machine, point, opts)
    end
  end

  @doc """
  Makes a key pair for a machine that is about to ask for a certificate
  (see `Wallboard.Pairing`). Returns `%{key_pem, public_pem}`. The private
  key stays with whoever called this; only `public_pem` goes to the hub.
  """
  def new_key_pair do
    key = new_key()
    point = ec_private_key(key, :publicKey)

    public =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {{:ECPoint, point}, @curve})
      ])

    %{key_pem: key_pem(key), public_pem: public}
  end

  @doc """
  The bytes of a public key given as PEM text, the same on both ends of a
  pairing. `{:ok, bytes}`, or `{:error, :bad_key}` for anything but one key
  on this authority's curve.
  """
  def public_bytes(public_key_pem) when is_binary(public_key_pem) do
    with {:ok, point} <- read_public(public_key_pem), do: {:ok, ec_point(point, :point)}
  end

  def public_bytes(_), do: {:error, :bad_key}

  @doc """
  The bytes of a certificate given as PEM text. `{:ok, bytes}`, or
  `{:error, :bad_cert}` for anything but one certificate that can be read.
  """
  def cert_bytes(pem) when is_binary(pem) do
    with [{:Certificate, der, :not_encrypted}] <- :public_key.pem_decode(pem),
         {:OTPCertificate, _, _, _} <- :public_key.pkix_decode_cert(der, :otp) do
      {:ok, der}
    else
      _ -> {:error, :bad_cert}
    end
  rescue
    _ -> {:error, :bad_cert}
  end

  def cert_bytes(_), do: {:error, :bad_cert}

  @doc """
  True when `cert_pem` is a certificate for `machine`, made for the key
  `public_pem`, and signed by the authority whose certificate is `ca_pem`.
  A collector checks this before it keeps what a pairing handed it.
  """
  def issued_for?(cert_pem, ca_pem, machine, public_pem) do
    with {:ok, der} <- cert_bytes(cert_pem),
         {:ok, ca_der} <- cert_bytes(ca_pem),
         {:ok, wanted} <- public_bytes(public_pem),
         {:ok, _serial, ^machine} <- read_cert(der),
         true <- :public_key.pkix_is_issuer(der, ca_der),
         true <- :public_key.pkix_verify(der, cert_key(ca_der)) do
      cert_key(der) == {ec_point(point: wanted), @curve}
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  True when the list of machines can be read right now. `machines/1` gives
  an empty list both for no machines and for a list it cannot read; this
  tells the two apart.
  """
  def readable?(dir), do: match?({:ok, _}, read_index(dir))

  @doc "True when a machine of this name holds a working certificate."
  def working?(dir, machine) do
    Enum.any?(machines(dir), &(&1.machine == machine and &1.revoked_at == nil))
  end

  @doc """
  Revokes every working certificate of a machine. Returns `{:ok, serials}`
  with the serial numbers revoked, which is empty when it had none.
  """
  def revoke(dir, machine) when is_binary(machine) do
    locked(dir, fn ->
      index = read_index!(dir)
      now = System.os_time(:second)

      serials = for {serial, %{"machine" => ^machine, "revoked_at" => nil}} <- index, do: serial

      index =
        Enum.reduce(serials, index, fn serial, acc ->
          Map.update!(acc, serial, &Map.put(&1, "revoked_at", now))
        end)

      if serials != [], do: write_index!(dir, index)
      {:ok, serials}
    end)
  end

  @doc "Every machine certificate issued: `%{machine, serial, issued_at, revoked_at}`."
  def machines(dir) do
    index =
      case read_index(dir) do
        {:ok, index} -> index
        :unreadable -> %{}
      end

    for {serial, m} <- index do
      %{
        machine: m["machine"],
        serial: serial,
        issued_at: m["issued_at"],
        revoked_at: m["revoked_at"]
      }
    end
    |> Enum.sort_by(&{&1.machine, &1.issued_at})
  end

  @doc """
  Whose certificate this is, from the certificate itself (as the TLS
  handshake gives it, DER encoded). `{:ok, machine}` only for a certificate
  this authority issued and has not revoked.
  """
  def machine(dir, cert_der) when is_binary(cert_der) do
    with {:ok, serial, name} <- read_cert(cert_der),
         {:ok, index} <- read_index(dir),
         %{"machine" => ^name, "revoked_at" => nil} <- index[serial] do
      {:ok, name}
    else
      %{"revoked_at" => at} when is_integer(at) -> {:error, :revoked}
      # The list itself could not be read just now. That says nothing
      # about this certificate either way.
      :unreadable -> {:error, :unreadable}
      _ -> {:error, :unknown}
    end
  end

  def machine(_dir, _cert), do: {:error, :unknown}

  @doc """
  The TLS settings for the hub's link port: TLS 1.3 only, the hub's
  certificate, and a client certificate required, signed by this authority
  and still working.
  """
  def hub_tls(dir) do
    {ca_cert, _} = ca!(dir)

    [
      cert: pem_der!(File.read!(path(dir, "hub.pem"))),
      key: {:ECPrivateKey, key_der!(File.read!(path(dir, "hub.key")))},
      cacerts: [ca_cert],
      versions: [:"tlsv1.3"],
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      verify_fun: {&__MODULE__.check_peer/3, dir},
      # No way back in without the full handshake, so a revoked machine
      # cannot ride on an older session.
      session_tickets: :disabled,
      alpn_preferred_protocols: ["h2"]
    ]
  end

  @doc """
  The TLS settings for a collector, from the three PEM texts it holds. It
  trusts only its hub's authority, and only a certificate made for a hub.
  """
  def collector_tls(%{cert_pem: cert, key_pem: key, ca_pem: ca}) do
    [
      cert: pem_der!(cert),
      key: {:ECPrivateKey, key_der!(key)},
      cacerts: [pem_der!(ca)],
      versions: [:"tlsv1.3"],
      verify: :verify_peer,
      server_name_indication: String.to_charlist(@hub_name),
      customize_hostname_check: [match_fun: fn _, _ -> :default end],
      depth: 1
    ]
  end

  @doc false
  # Called by the TLS handshake for each certificate a peer presents.
  def check_peer(_cert, {:bad_cert, _} = reason, _dir), do: {:fail, reason}
  def check_peer(_cert, {:extension, _}, dir), do: {:unknown, dir}
  def check_peer(_cert, :valid, dir), do: {:valid, dir}

  def check_peer(cert, :valid_peer, dir) do
    der = :public_key.pkix_encode(:OTPCertificate, cert, :otp)

    case machine(dir, der) do
      {:ok, _} -> {:valid, dir}
      {:error, :revoked} -> {:fail, {:bad_cert, :cert_revoked}}
      {:error, _} -> {:fail, {:bad_cert, :unknown_ca}}
    end
  rescue
    _ -> {:fail, {:bad_cert, :unknown_ca}}
  end

  # ---------------------------------------------------------------------------
  # Issuing

  defp sign_public(dir, machine, point, opts) do
    if machine_name?(machine) do
      locked(dir, fn ->
        index = read_index!(dir)
        now = System.os_time(:second)
        working = for {s, %{"machine" => ^machine, "revoked_at" => nil}} <- index, do: s

        cond do
          working != [] and opts[:replace] != true ->
            {:error, :taken}

          true ->
            {ca_cert, ca_key} = ca!(dir)
            tbs = tbs(machine, point, :machine, ca_cert)
            serial = serial_text(otp_tbs_certificate(tbs, :serialNumber))
            cert = sign(tbs, ca_key)

            index =
              working
              |> Enum.reduce(index, fn s, acc ->
                Map.update!(acc, s, &Map.put(&1, "revoked_at", now))
              end)
              |> Map.put(serial, %{"machine" => machine, "issued_at" => now, "revoked_at" => nil})

            write_index!(dir, index)
            {:ok, %{cert_pem: cert_pem(cert), ca_pem: ca_pem(dir), serial: serial}}
        end
      end)
    else
      {:error, :bad_name}
    end
  end

  @doc "True for a name a machine certificate can carry: what `hostname` prints, more or less."
  def machine_name?(name) do
    # Never the hub's own name: a machine's certificate must not read as
    # the hub's.
    # It ends as it starts, on a letter or a digit, so two names never
    # differ only by a dot or a space at the end.
    is_binary(name) and name =~ ~r/\A[A-Za-z0-9]([A-Za-z0-9 ._-]{0,61}[A-Za-z0-9])?\z/ and
      String.downcase(name) != @hub_name
  end

  defp new_key, do: :public_key.generate_key(@curve)

  defp public(key), do: ec_point(point: ec_private_key(key, :publicKey))

  defp tbs(name, point, kind, ca_cert) do
    subject =
      {:rdnSequence, [[attribute_type_and_value(type: @common_name, value: {:utf8String, name})]]}

    issuer =
      if ca_cert do
        ca_cert
        |> :public_key.pkix_decode_cert(:otp)
        |> otp_certificate(:tbsCertificate)
        |> otp_tbs_certificate(:subject)
      else
        subject
      end

    now = DateTime.utc_now()

    otp_tbs_certificate(
      version: :v3,
      serialNumber: :crypto.strong_rand_bytes(15) |> :binary.decode_unsigned() |> Kernel.+(1),
      signature: signature_algorithm(algorithm: @ecdsa_sha256, parameters: :asn1_NOVALUE),
      issuer: issuer,
      # An hour back, so a collector whose clock runs a little behind still
      # accepts a certificate made a moment ago.
      validity:
        validity(
          notBefore: time(DateTime.add(now, -3600, :second)),
          notAfter: time(DateTime.add(now, @years * 365 * 86_400, :second))
        ),
      subject: subject,
      subjectPublicKeyInfo:
        otp_subject_public_key_info(
          algorithm: public_key_algorithm(algorithm: @ec_public_key, parameters: @curve),
          subjectPublicKey: point
        ),
      extensions: extensions(kind)
    )
  end

  defp extensions(:ca) do
    [
      extension(
        extnID: @basic_constraints,
        critical: true,
        extnValue: basic_constraints(cA: true, pathLenConstraint: 0)
      ),
      extension(extnID: @key_usage, critical: true, extnValue: [:keyCertSign, :cRLSign])
    ]
  end

  defp extensions(:hub) do
    leaf(@server_auth) ++
      [
        extension(
          extnID: @subject_alt_name,
          critical: false,
          extnValue: [dNSName: String.to_charlist(@hub_name)]
        )
      ]
  end

  defp extensions(:machine), do: leaf(@client_auth)

  defp leaf(usage) do
    [
      extension(
        extnID: @basic_constraints,
        critical: true,
        extnValue: basic_constraints(cA: false)
      ),
      extension(extnID: @key_usage, critical: true, extnValue: [:digitalSignature]),
      extension(extnID: @ext_key_usage, critical: true, extnValue: [usage])
    ]
  end

  defp time(%DateTime{year: year} = at) when year < 2050,
    do: {:utcTime, at |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()}

  defp time(at),
    do: {:generalTime, at |> Calendar.strftime("%Y%m%d%H%M%SZ") |> String.to_charlist()}

  defp sign(tbs, key), do: :public_key.pkix_sign(tbs, key)

  # ---------------------------------------------------------------------------
  # Reading

  defp read_cert(der) do
    tbs = der |> :public_key.pkix_decode_cert(:otp) |> otp_certificate(:tbsCertificate)

    name =
      case otp_tbs_certificate(tbs, :subject) do
        {:rdnSequence, [[{:AttributeTypeAndValue, @common_name, {_, name}}]]} -> to_string(name)
        _ -> nil
      end

    if name, do: {:ok, serial_text(otp_tbs_certificate(tbs, :serialNumber)), name}, else: :error
  rescue
    _ -> :error
  end

  # The public key a certificate carries, as `:public_key` wants it for
  # checking a signature.
  defp cert_key(der) do
    info =
      der
      |> :public_key.pkix_decode_cert(:otp)
      |> otp_certificate(:tbsCertificate)
      |> otp_tbs_certificate(:subjectPublicKeyInfo)

    {otp_subject_public_key_info(info, :subjectPublicKey),
     public_key_algorithm(otp_subject_public_key_info(info, :algorithm), :parameters)}
  end

  defp read_public(pem) do
    with [{:SubjectPublicKeyInfo, _, :not_encrypted} = entry] <- :public_key.pem_decode(pem),
         {{:ECPoint, point}, @curve} when is_binary(point) <-
           :public_key.pem_entry_decode(entry) do
      {:ok, ec_point(point: point)}
    else
      _ -> {:error, :bad_key}
    end
  rescue
    _ -> {:error, :bad_key}
  end

  defp ca!(dir) do
    cert = pem_der!(File.read!(path(dir, "ca.pem")))
    [entry] = :public_key.pem_decode(File.read!(path(dir, "ca.key")))
    {cert, :public_key.pem_entry_decode(entry)}
  end

  defp pem_der!(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end

  defp key_der!(pem) do
    [{:ECPrivateKey, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end

  defp cert_pem(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  defp key_pem(key),
    do: :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])

  defp serial_text(n), do: n |> Integer.to_string(16) |> String.downcase()

  # ---------------------------------------------------------------------------
  # Files

  defp path(dir, name), do: Path.join(dir, name)

  # A list that cannot be read vouches for nobody: a new connection is
  # refused. It does not condemn anybody either: see `machine/2`.
  defp read_index(dir) do
    with {:ok, text} <- File.read(path(dir, "machines.json")),
         {:ok, %{} = index} <- Jason.decode(text) do
      {:ok, index}
    else
      _ -> :unreadable
    end
  end

  # For a change to the list. A list that is there but cannot be read is
  # never written over: that would forget every machine in it.
  defp read_index!(dir) do
    file = path(dir, "machines.json")

    with true <- File.exists?(file),
         {:ok, text} <- File.read(file),
         {:ok, %{} = index} <- Jason.decode(text) do
      index
    else
      false -> %{}
      _ -> raise "#{file} cannot be read. Mend it or restore it; it is not replaced."
    end
  end

  defp write_index!(dir, index), do: write!(dir, "machines.json", Jason.encode!(index))

  # Written beside the file and moved over it, so a reader never sees half
  # a file, and never for a moment with wider permissions.
  defp write!(dir, name, text) do
    tmp = path(dir, ".#{name}.#{System.unique_integer([:positive])}.tmp")
    File.write!(tmp, "")
    File.chmod!(tmp, 0o600)
    File.write!(tmp, text)
    File.rename!(tmp, path(dir, name))
  end

  # One writer at a time, across programs too: a `mix` task may issue a
  # certificate while the hub runs.
  defp locked(dir, fun, waited \\ 0) do
    lock = path(dir, ".lock")

    case File.open(lock, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)

        try do
          fun.()
        after
          File.rm(lock)
        end

      {:error, :eexist} ->
        stale? =
          case File.stat(lock, time: :posix) do
            {:ok, %{mtime: at}} -> System.os_time(:second) - at > @lock_stale_s
            _ -> false
          end

        cond do
          stale? ->
            File.rm(lock)
            locked(dir, fun, waited)

          waited >= @lock_wait_ms ->
            raise "the link folder #{dir} is locked by another program"

          true ->
            Process.sleep(50)
            locked(dir, fun, waited + 50)
        end
    end
  end
end
