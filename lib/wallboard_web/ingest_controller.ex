defmodule WallboardWeb.IngestController do
  @moduledoc """
  Where other machines send their Claude and Codex sessions, connect, and
  fetch the scripts that do it. Sessions and statuses must be signed with
  the sending machine's own key, and a machine connects with a request
  signed with the connect key (see Wallboard.Archive.MachineKeys). The
  scripts hold no key, so anyone may fetch them.
  """

  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias Wallboard.Archive.{Ingest, MachineKeys, UploadGate}

  # Read a megabyte at a time, one socket read each (read_length equal to
  # length), so every read ends by the upload's deadline.
  @chunk 1_000_000

  def transcript(conn, _params) do
    settings = Wallboard.Settings.get()

    with :ok <- enabled(settings),
         {:ok, params} <- query_only(conn),
         {:ok, parts} <- signed(conn, params, :machine),
         {:ok, length} <- declared_length(conn),
         :ok <- admit(parts.key_id, length) do
      receive_upload(conn, params, parts, settings)
    else
      {:error, status, reason} -> text(conn, status, reason)
    end
  end

  # Key ids are not secret, so anyone on the network can start an upload.
  # Until its signature is checked, its body goes to a file in a folder only
  # this user can open, hashed on the way, and UploadGate caps how many such
  # files there are. Only a checked upload is read into memory, and only two
  # unpack at once.
  defp receive_upload(conn, params, parts, settings) do
    file = staging_file(settings)

    try do
      with {:ok, hash, conn} <- read_to_file(conn, file),
           {:ok, machine} <- MachineKeys.verify(conn, parts, {:sha256, hash}),
           :ok <- own_machine(machine, params["machine"]) do
        UploadGate.checked()
        UploadGate.unpack(fn -> save_upload(conn, File.read!(file), params, settings) end)
      else
        {:error, status, reason} -> text(conn, status, reason)
      end
    after
      UploadGate.checked()
      File.rm(file)
    end
  end

  defp save_upload(conn, body, params, settings) do
    case save(params["tool"] || "claude", body, params, settings) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(
          Wallboard.PubSub,
          Wallboard.Poller.topic(),
          {:archive, :upload}
        )

        send_resp(conn, 200, "saved\n")

      {:error, :too_big} ->
        text(conn, 413, "the upload unpacks to more than the hub takes")

      {:error, reason} ->
        text(conn, 422, reason)
    end
  end

  # A status is one Claude hook's JSON: a notification or a question, never
  # a transcript.
  @max_status 256_000

  @doc """
  A collector's session starting or stopping to wait on its person (see
  Wallboard.Remote). The body is the Claude hook's JSON; `at` is the
  collector's clock in milliseconds.
  """
  def status(conn, _params) do
    settings = Wallboard.Settings.get()

    with :ok <- enabled(settings),
         {:ok, params} <- query_only(conn),
         {:ok, parts} <- signed(conn, params, :machine),
         {:ok, body, conn} <- read_small(conn),
         {:ok, machine} <- MachineKeys.verify(conn, parts, body),
         :ok <- own_machine(machine, params["machine"]),
         {:ok, hook} <- decode(body),
         account = params["account"] || "claude",
         true <- Ingest.valid_name?(account) || {:error, 422, "bad account name"},
         :ok <- report(hook, machine, account, params["at"]) do
      send_resp(conn, 200, "ok\n")
    else
      {:error, status, reason} -> text(conn, status, reason)
    end
  end

  @doc """
  Connects a machine: a request signed with the connect key, naming the
  machine and the key id it made (see MachineKeys.connect/5).
  """
  def connect(conn, _params) do
    settings = Wallboard.Settings.get()

    with :ok <- enabled(settings),
         {:ok, params} <- query_only(conn),
         {:ok, parts} <- signed(conn, params, :connect),
         {:ok, body, conn} <- read_empty(conn),
         {:ok, nil} <- MachineKeys.verify(conn, parts, body),
         machine = params["machine"],
         true <- Ingest.valid_name?(machine) || {:error, 422, "bad machine name"},
         :ok <- MachineKeys.connect(machine, params["key"], params["replaces"], parts.secret) do
      text(conn, 200, "connected as #{machine}")
    else
      {:error, status, reason} -> text(conn, status, reason)
    end
  end

  # The signed parts of a request, checked before its body is read. The
  # connect key signs the connect request and nothing else. A request with
  # no signature but the shared key from before 0.3.0 comes from a machine
  # connected by an earlier version: it is noted, so Settings can say to
  # connect that machine again.
  defp signed(conn, params, kind) do
    case {MachineKeys.precheck(conn), kind} do
      {{:ok, %{key_id: "connect"} = parts}, :connect} -> {:ok, parts}
      {{:ok, %{key_id: "connect"}}, :machine} -> {:error, 401, "sign with this machine's key"}
      {{:ok, _}, :connect} -> {:error, 401, "sign with the connect key"}
      {{:ok, parts}, :machine} -> {:ok, parts}
      {{:error, :unsigned}, _} -> old_key(conn, params)
      {error, _} -> error
    end
  end

  defp old_key(conn, params) do
    given =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> t] -> String.trim(t)
        _ -> nil
      end

    if MachineKeys.old_shared_key?(given) do
      if Ingest.valid_name?(params["machine"]), do: MachineKeys.note_old_try(params["machine"])

      {:error, 401,
       "this machine uses the old shared key: run the connect command from the hub's Settings page again"}
    else
      {:error, 401, "unsigned request"}
    end
  end

  # What a signed request says comes from its query, which the signature
  # covers. A body sent as a form would be parsed into the parameters
  # before the controller reads it, and it would not be what was signed.
  defp query_only(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> {:ok, conn.query_params}
      empty when empty == %{} -> {:ok, conn.query_params}
      _ -> {:error, 400, "send the body as data, not as a form"}
    end
  end

  # An upload says how long it is, so it can be turned away before any of
  # it is read. A compressed upload is never much larger than what it
  # unpacks to, so the unpacking limit caps it too.
  defp declared_length(conn) do
    with [value] <- get_req_header(conn, "content-length"),
         {n, ""} when n >= 0 <- Integer.parse(value) do
      if n > Ingest.max_unpacked(), do: {:error, 413, "upload too large"}, else: {:ok, n}
    else
      _ -> {:error, 411, "say how long the upload is"}
    end
  end

  defp admit(key_id, length) do
    case UploadGate.admit(key_id, length) do
      :ok -> :ok
      {:error, reason} -> {:error, 503, reason}
    end
  end

  defp own_machine(machine, machine), do: :ok
  defp own_machine(_, _), do: {:error, 403, "this key belongs to another machine"}

  defp enabled(settings) do
    if settings.archive.enabled,
      do: :ok,
      else: {:error, 404, "the archive is turned off on this board"}
  end

  # A connect request has no body, and anyone may send one.
  defp read_empty(conn) do
    case read_body(conn, length: 1, read_timeout: 15_000) do
      {:ok, "", conn} -> {:ok, "", conn}
      {:error, _} -> {:error, 400, "could not read the request"}
      _ -> {:error, 413, "a connect request has no body"}
    end
  end

  defp read_small(conn) do
    case read_body(conn, length: @max_status, read_timeout: 15_000) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _, _} -> {:error, 413, "request too large"}
      {:error, _} -> {:error, 400, "could not read the request"}
    end
  end

  defp decode(body) do
    # Copied strings, so what is kept does not hold the whole body in memory.
    case Jason.decode(body, strings: :copy) do
      {:ok, %{} = hook} -> {:ok, hook}
      _ -> {:error, 422, "expected the hook's JSON"}
    end
  end

  defp report(hook, machine, account, at) do
    at =
      with true <- is_binary(at),
           {n, ""} <- Integer.parse(at) do
        n
      else
        _ -> System.os_time(:millisecond)
      end

    case Wallboard.Remote.report(
           hook,
           machine,
           Wallboard.Sources.Claude.account_label(account),
           at
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, 422, reason}
    end
  end

  defp save("claude", body, params, settings),
    do: Ingest.receive(body, params["machine"], params["account"] || "claude", settings)

  defp save("codex", body, params, settings),
    do: Ingest.receive_codex(body, params["machine"], params["account"] || "codex", settings)

  defp save(_tool, _body, _params, _settings), do: {:error, "unknown tool"}

  @doc """
  The connect script. It holds no key: it asks for the connect key. The
  connect command on the settings page checks it against its SHA-256
  before running it, since it comes over plain http.
  """
  def install(conn, _params), do: script(conn, &Ingest.install_script/1)

  @doc "Just the upload script, for the Wallboard app to save and hook up itself."
  def upload(conn, _params), do: script(conn, &Ingest.upload_script/1)

  @doc "Just the Codex upload script, for the Wallboard app to save and hook up itself."
  def codex_upload(conn, _params), do: script(conn, &Ingest.codex_upload_script/1)

  # Each script comes with an HMAC of its name and itself made with the
  # connect key, so the Mac app, which holds that key, can check nobody on
  # the network changed it, or sent one script for another, before it runs
  # it on every turn.
  defp script(conn, make) do
    settings = Wallboard.Settings.get()

    case enabled(settings) do
      :ok ->
        body = make.(hub_url(settings))
        name = Path.basename(conn.request_path)

        conn
        |> put_resp_content_type("text/x-shellscript")
        |> put_resp_header(
          "x-vitalaize-script-signature",
          MachineKeys.script_signature(name, body)
        )
        |> send_resp(200, body)

      {:error, status, reason} ->
        text(conn, status, reason)
    end
  end

  # Plain text, so a browser never reads an error (or a reply naming what
  # the request sent) as a page.
  defp text(conn, status, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, reason <> "\n")
  end

  @doc """
  The address other machines reach this board at. It goes into the scripts
  the board signs, so only a plain address (Settings.hub_url?/1) is used.
  """
  def hub_url(settings) do
    url = settings.archive[:hub_url]
    url = is_binary(url) && String.trim_trailing(url, "/")

    if url && Wallboard.Settings.hub_url?(url) do
      url
    else
      host = List.first(Wallboard.Network.lan_addresses()) || "localhost"
      "http://#{host}:#{settings.port}"
    end
  end

  # A new file with a random name, in a folder beside the database that
  # only this user can open. Files older than the upload deadline are left
  # over from a hub that stopped mid-upload, and are removed here.
  defp staging_file(settings) do
    dir = Path.join(Path.dirname(settings.archive.path), "incoming")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    old = System.os_time(:second) - MachineKeys.upload_deadline() - 60

    for f <- File.ls!(dir),
        path = Path.join(dir, f),
        match?({:ok, %{mtime: m}} when m < old, File.stat(path, time: :posix)),
        do: File.rm(path)

    name = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    Path.join(dir, name)
  end

  # Writes the body to `file` and returns its SHA-256, stopping at the
  # upload deadline.
  defp read_to_file(conn, file) do
    deadline = System.monotonic_time(:millisecond) + MachineKeys.upload_deadline() * 1000

    case File.open(file, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          read_chunks(conn, io, :crypto.hash_init(:sha256), deadline)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, 500, "the hub could not store the upload (#{reason})"}
    end
  end

  defp read_chunks(conn, io, hash, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    result =
      if left > 0,
        do: read_body(conn, length: @chunk, read_length: @chunk, read_timeout: min(left, 60_000)),
        else: {:error, :deadline}

    case result do
      {status, chunk, conn} when status in [:ok, :more] ->
        # :file.write says when the disk is full; IO.binwrite does not.
        case :file.write(io, chunk) do
          :ok ->
            hash = :crypto.hash_update(hash, chunk)

            if status == :ok,
              do: {:ok, :crypto.hash_final(hash) |> Base.encode16(case: :lower), conn},
              else: read_chunks(conn, io, hash, deadline)

          {:error, reason} ->
            {:error, 507, "the hub could not store the upload (#{reason})"}
        end

      {:error, _} ->
        {:error, 400, "could not read the upload in time"}
    end
  end
end
