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

  alias Wallboard.Archive.{Ingest, MachineKeys}

  def transcript(conn, params) do
    settings = Wallboard.Settings.get()

    with :ok <- enabled(settings),
         {:ok, parts} <- signed(conn, params, :machine),
         {:ok, body, conn} <- read_all(conn, []),
         {:ok, machine} <- MachineKeys.verify(conn, parts, body),
         :ok <- own_machine(machine, params["machine"]) do
      case save(params["tool"] || "claude", body, params, settings) do
        {:ok, _} ->
          Phoenix.PubSub.broadcast(
            Wallboard.PubSub,
            Wallboard.Poller.topic(),
            {:archive, :upload}
          )

          send_resp(conn, 200, "saved\n")

        {:error, :too_big} ->
          send_resp(conn, 413, "the upload unpacks to more than the hub takes\n")

        {:error, reason} ->
          send_resp(conn, 422, reason <> "\n")
      end
    else
      {:error, status, reason} -> send_resp(conn, status, reason <> "\n")
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
  def status(conn, params) do
    settings = Wallboard.Settings.get()

    with :ok <- enabled(settings),
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
      {:error, status, reason} -> send_resp(conn, status, reason <> "\n")
    end
  end

  @doc """
  Connects a machine: a request signed with the connect key, naming the
  machine and the key id it made (see MachineKeys.connect/3).
  """
  def connect(conn, params) do
    settings = Wallboard.Settings.get()

    with :ok <- enabled(settings),
         {:ok, parts} <- signed(conn, params, :connect),
         {:ok, body, conn} <- read_small(conn),
         {:ok, nil} <- MachineKeys.verify(conn, parts, body),
         machine = params["machine"],
         true <- Ingest.valid_name?(machine) || {:error, 422, "bad machine name"},
         :ok <- MachineKeys.connect(machine, params["key"], params["replaces"]) do
      send_resp(conn, 200, "connected as #{machine}\n")
    else
      {:error, status, reason} -> send_resp(conn, status, reason <> "\n")
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
      {{:error, 401, "unsigned request"}, _} -> old_key(conn, params)
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

  defp own_machine(machine, machine), do: :ok
  defp own_machine(_, _), do: {:error, 403, "this key belongs to another machine"}

  defp enabled(settings) do
    if settings.archive.enabled,
      do: :ok,
      else: {:error, 404, "the archive is turned off on this board"}
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

  @doc "The connect script. It holds no key: the command hands it the connect key."
  def install(conn, _params), do: script(conn, &Ingest.install_script/1)

  @doc "Just the upload script, for the Wallboard app to save and hook up itself."
  def upload(conn, _params), do: script(conn, &Ingest.upload_script/1)

  @doc "Just the Codex upload script, for the Wallboard app to save and hook up itself."
  def codex_upload(conn, _params), do: script(conn, &Ingest.codex_upload_script/1)

  defp script(conn, make) do
    settings = Wallboard.Settings.get()

    case enabled(settings) do
      :ok ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(200, make.(hub_url(settings)))

      {:error, status, reason} ->
        send_resp(conn, status, reason <> "\n")
    end
  end

  @doc "The address other Macs reach this board at."
  def hub_url(settings) do
    case settings.archive[:hub_url] do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        host = List.first(Wallboard.Network.lan_addresses()) || "localhost"
        "http://#{host}:#{settings.port}"
    end
  end

  # A compressed upload is never larger than what it unpacks to, so the
  # unpacking limit caps the body too.
  defp read_all(conn, acc) do
    case read_body(conn, length: 8_000_000, read_timeout: 60_000) do
      {:ok, chunk, conn} -> check_size([chunk | acc], conn, &finish/2)
      {:more, chunk, conn} -> check_size([chunk | acc], conn, &read_all(&2, &1))
      {:error, _} -> {:error, 400, "could not read the upload"}
    end
  end

  defp check_size(acc, conn, next) do
    if IO.iodata_length(acc) > Ingest.max_unpacked(),
      do: {:error, 413, "upload too large"},
      else: next.(acc, conn)
  end

  defp finish(acc, conn), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), conn}
end
