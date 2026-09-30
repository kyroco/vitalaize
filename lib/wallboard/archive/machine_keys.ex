defmodule Wallboard.Archive.MachineKeys do
  @moduledoc """
  Who may send sessions to this board, and proof that a request came from
  them. The board is reached over plain http on the home network, so no key
  is ever sent: each request carries a signature made with the key instead.

  There are two kinds of key.

    * The connect key, shown on the settings page. It is only ever used on
      the machine being connected, to sign one request that names the
      machine, and to work out that machine's own key.
    * Each connected machine's own key. The connect command makes a random
      key id on that machine and works out the key from the connect key
      and that id (`derive/2`). The board, holding the connect key too,
      works out the same key and keeps it with the machine's name. Neither
      side ever sends it.

  A signed request carries five headers: the key id, the time in seconds,
  a random nonce, the SHA-256 of its body, and an HMAC-SHA256 made with the
  key over the method, path, query, time, nonce and that body hash
  (`message/6`). So the hub checks the signature, and claims the nonce,
  before it reads any of the body (authenticate/1), and then checks the
  body against the signed hash as it reads (confirm/2). Nobody without a
  machine's key can make the hub read or keep anything. The board refuses
  a request whose time is more than five minutes from its own, whose nonce
  that key already used, whose signature is wrong, or whose body is not
  the one signed. A machine's key can only send for the machine it was
  made for, and removing it on the settings page leaves every other
  machine connected.

  What this does not hide: the sessions themselves still cross the network
  as they are (see the README).
  """

  alias Wallboard.Store

  # How far a request's time may be from the board's clock, in seconds.
  @window 300

  # The longest an upload's body may take to arrive, in seconds. The upload
  # endpoint stops reading at this deadline.
  @upload_deadline 600

  # How long a nonce is kept. It is claimed before the body is read, so only
  # the window matters: past it, a copy of the request is stale anyway.
  @keep_nonces @window + 60

  @key_id ~r/\A[0-9a-f]{32}\z/
  @nonce ~r/\A[0-9a-f]{16,64}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @doc "How far a request's time may be from this board's clock, in seconds."
  def window, do: @window

  @doc "The longest an upload's body may take to arrive, in seconds."
  def upload_deadline, do: @upload_deadline

  @doc "How long a nonce is kept, in seconds."
  def keep_nonces, do: @keep_nonces

  @doc """
  The connect key, made on first use and then kept. It is never the shared
  key a board from 0.2.0 or earlier made (kept as "ingest_token"), since
  that one crossed the network with every upload; that one is only used to
  spot machines still sending with it.
  """
  def connect_key do
    case Store.get_meta("connect_key") do
      k when is_binary(k) -> k
      _ -> new_connect_key()
    end
  end

  @doc "Makes the connect key. A board without one gets one on first use."
  def new_connect_key do
    k = random_key()
    Store.put_meta("connect_key", k)
    k
  end

  @doc """
  Replaces the connect key and disconnects every machine, in one step, for
  when the old key may have been seen: whoever saw it could work out the
  keys of machines connected with it. A connect already on its way with the
  old key finds it gone (see connect/5).
  """
  def reset_connect_key do
    k = random_key()

    case Store.reset_connect_key(k) do
      :ok -> {:ok, k}
      {:error, reason} -> {:error, reason}
    end
  end

  defp random_key, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "True when `given` is the shared key collectors used before 0.3.0."
  def old_shared_key?(given) when is_binary(given) do
    case Store.get_meta("ingest_token") do
      old when is_binary(old) -> Plug.Crypto.secure_compare(given, old)
      _ -> false
    end
  end

  def old_shared_key?(_), do: false

  @doc "A machine's key, worked out from the connect key and its key id."
  def derive(connect_key, key_id), do: hmac(connect_key, "vitalaize machine key\n" <> key_id)

  @doc """
  The HMAC of a script the hub serves, over its name and itself, made with
  the connect key.
  """
  def script_signature(name, body),
    do: hmac(connect_key(), "vitalaize script\n" <> name <> "\n" <> body)

  @doc """
  What a request's signature is made over. `body` is the body itself, or
  {:sha256, hex}: the hash the request says its body has.
  """
  def message(method, path, query, time, nonce, {:sha256, hash}),
    do: Enum.join(["vitalaize-v1", method, path, query, time, nonce, hash], "\n")

  def message(method, path, query, time, nonce, body),
    do: message(method, path, query, time, nonce, {:sha256, sha256(body)})

  @doc "The SHA-256 of `data`, in lower-case hex."
  def sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  @doc "The HMAC-SHA256 of `message` with `key`, in lower-case hex."
  def hmac(key, message),
    do: :crypto.mac(:hmac, :sha256, key, message) |> Base.encode16(case: :lower)

  @doc """
  Checks a request before any of its body is read: the headers are there
  and well formed, the time is recent, the key is known, the signature over
  the method, path, query, time, nonce and stated body hash is right, and
  the nonce is new. Only then is the nonce claimed (Store.claim_nonce/5,
  on the database's own clock), so a request that is not signed right
  writes nothing.

  {:ok, parts} with the machine (nil for the connect key); {:error,
  :unsigned} when no header is there; otherwise {:error, status, reason}.
  """
  def authenticate(conn) do
    with {:ok, parts} <- headers(conn),
         :ok <- fresh(parts.time, System.os_time(:second)),
         {:ok, secret, machine} <- secret(parts.key_id),
         :ok <- signed_right(conn, parts, secret),
         :ok <- claim(parts) do
      {:ok, Map.merge(parts, %{secret: secret, machine: machine})}
    end
  end

  defp signed_right(conn, parts, secret) do
    expected =
      hmac(
        secret,
        message(
          conn.method,
          conn.request_path,
          conn.query_string,
          parts.time,
          parts.nonce,
          {:sha256, parts.body_sha256}
        )
      )

    if Plug.Crypto.secure_compare(expected, parts.signature),
      do: :ok,
      else: {:error, 401, "wrong signature"}
  end

  @doc """
  Once the body is in: its SHA-256 (`hash`, lower-case hex) is the one that
  was signed, and the key was not taken away while it came. {:ok, machine}
  or {:error, status, reason}.
  """
  def confirm(parts, hash, now \\ System.os_time(:second)) do
    cond do
      not Plug.Crypto.secure_compare(hash, parts.body_sha256) ->
        {:error, 400, "the body is not the one that was signed"}

      # Disconnected, or given a new connect key, while its body came.
      secret(parts.key_id) != {:ok, parts.secret, parts.machine} ->
        {:error, 401, "this machine's key was taken away"}

      true ->
        if parts.machine,
          do:
            Store.write("UPDATE machine_keys SET last_used_at = ?1 WHERE key_id = ?2", [
              now,
              parts.key_id
            ])

        {:ok, parts.machine}
    end
  end

  defp claim(parts) do
    case Store.claim_nonce(
           parts.key_id,
           parts.nonce,
           String.to_integer(parts.time),
           @window,
           @keep_nonces
         ) do
      :ok -> :ok
      :seen -> {:error, 401, "this request was already sent once"}
      :stale -> stale()
    end
  end

  defp headers(conn) do
    get = &(conn |> Plug.Conn.get_req_header(&1) |> List.first())

    parts = %{
      key_id: get.("x-vitalaize-key"),
      time: get.("x-vitalaize-time"),
      nonce: get.("x-vitalaize-nonce"),
      body_sha256: get.("x-vitalaize-content-sha256"),
      signature: get.("x-vitalaize-signature")
    }

    cond do
      Enum.all?(Map.values(parts), &is_nil/1) ->
        {:error, :unsigned}

      not (is_binary(parts.key_id) and (parts.key_id == "connect" or parts.key_id =~ @key_id)) or
        not (is_binary(parts.time) and parts.time =~ ~r/\A[0-9]{1,12}\z/) or
        not (is_binary(parts.nonce) and parts.nonce =~ @nonce) or
        not (is_binary(parts.body_sha256) and parts.body_sha256 =~ @hex64) or
          not (is_binary(parts.signature) and parts.signature =~ @hex64) ->
        {:error, 401, "badly signed request"}

      true ->
        {:ok, parts}
    end
  end

  defp fresh(time, now) do
    if abs(String.to_integer(time) - now) <= @window, do: :ok, else: stale()
  end

  defp stale,
    do:
      {:error, 401,
       "request time is more than #{div(@window, 60)} minutes from the hub's clock: check both clocks"}

  defp secret("connect"), do: {:ok, connect_key(), nil}

  defp secret(key_id) do
    case Store.query("SELECT machine, secret FROM machine_keys WHERE key_id = ?1", [key_id]) do
      [%{machine: m, secret: s}] ->
        {:ok, s, m}

      _ ->
        {:error, 401,
         "this machine's key is not known here: run the connect command from the hub's Settings page again"}
    end
  end

  # ---------------------------------------------------------------------------
  # Connected machines

  @doc """
  Connects a machine: keeps the key worked out for `key_id` from
  `connect_key` (the one the request was signed with) under `machine`.
  When `replaces` names an earlier key of the same machine (the connect
  command run there again), that one goes. All in one database step, and
  only while `connect_key` is still the connect key, so a new connect key
  made meanwhile cannot leave behind a machine connected with the old one.
  """
  def connect(machine, key_id, replaces, connect_key, now \\ System.os_time(:second)) do
    # Never the key being saved: it would be dropped as soon as it was kept.
    replaces = if is_binary(replaces) and replaces =~ @key_id and replaces != key_id, do: replaces

    if is_binary(key_id) and key_id =~ @key_id do
      case Store.connect_machine(
             %{
               key_id: key_id,
               machine: machine,
               secret: derive(connect_key, key_id),
               created_at: now,
               replaces: replaces
             },
             connect_key
           ) do
        :ok -> :ok
        :taken -> {:error, 409, "that key id is taken"}
        :key_changed -> {:error, 401, "the connect key changed: copy the new one"}
        {:error, reason} -> {:error, 500, "the hub could not save the key (#{reason})"}
      end
    else
      {:error, 422, "bad key id"}
    end
  end

  @doc "Every machine key, newest first, without the secrets."
  def list do
    Store.query(
      "SELECT key_id, machine, created_at, last_used_at FROM machine_keys ORDER BY machine, created_at DESC",
      []
    )
  end

  @doc "Removes one machine key. That machine stops sending until connected again."
  def revoke(key_id), do: Store.write("DELETE FROM machine_keys WHERE key_id = ?1", [key_id])

  @doc """
  Notes that `machine` sent with the old shared key and was turned away.
  The old key crossed the network for months, so anyone may hold it: only
  a machine this board already has sessions from is noted.
  """
  def note_old_try(machine, now \\ System.os_time(:second)) do
    if Store.query("SELECT 1 AS x FROM sessions WHERE machine = ?1 LIMIT 1", [machine]) != [],
      do:
        Store.write("INSERT OR REPLACE INTO old_key_tries (machine, at) VALUES (?1, ?2)", [
          machine,
          now
        ])

    :ok
  end

  @doc "Machines still sending with the old shared key, most recent first."
  def old_tries, do: Store.query("SELECT machine, at FROM old_key_tries ORDER BY at DESC", [])
end
