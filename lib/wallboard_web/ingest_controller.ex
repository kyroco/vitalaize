defmodule WallboardWeb.IngestController do
  @moduledoc """
  Where other Macs send their Claude and Codex sessions, and fetch the
  script that connects them. Every request needs this board's ingest key as a Bearer
  token (see Wallboard.Archive.Ingest).
  """

  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias Wallboard.Archive.Ingest

  # A long session's transcript can be large, even compressed.
  @max_upload 300_000_000

  def transcript(conn, params) do
    settings = Wallboard.Settings.get()

    with :ok <- authorize(conn, settings),
         {:ok, body, conn} <- read_all(conn, []) do
      case save(params["tool"] || "claude", body, params, settings) do
        {:ok, _} ->
          Phoenix.PubSub.broadcast(
            Wallboard.PubSub,
            Wallboard.Poller.topic(),
            {:archive, :upload}
          )

          send_resp(conn, 200, "saved\n")

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

    with :ok <- authorize(conn, settings),
         {:ok, body, conn} <- read_small(conn),
         {:ok, hook} <- decode(body),
         true <- Ingest.valid_name?(params["machine"]) || {:error, 422, "bad machine name"},
         account = params["account"] || "claude",
         true <- Ingest.valid_name?(account) || {:error, 422, "bad account name"},
         :ok <- report(hook, params["machine"], account, params["at"]) do
      send_resp(conn, 200, "ok\n")
    else
      {:error, status, reason} -> send_resp(conn, status, reason <> "\n")
    end
  end

  defp read_small(conn) do
    case read_body(conn, length: @max_status, read_timeout: 15_000) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _, _} -> {:error, 413, "status too large"}
      {:error, _} -> {:error, 400, "could not read the status"}
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

  def install(conn, _params) do
    settings = Wallboard.Settings.get()

    case authorize(conn, settings) do
      :ok ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(200, Ingest.install_script(hub_url(settings), Ingest.token()))

      {:error, status, reason} ->
        send_resp(conn, status, reason <> "\n")
    end
  end

  @doc "Just the upload script, for the Wallboard app to save and hook up itself."
  def upload(conn, _params) do
    settings = Wallboard.Settings.get()

    case authorize(conn, settings) do
      :ok ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(200, Ingest.upload_script(hub_url(settings), Ingest.token()))

      {:error, status, reason} ->
        send_resp(conn, status, reason <> "\n")
    end
  end

  @doc "Just the Codex upload script, for the Wallboard app to save and hook up itself."
  def codex_upload(conn, _params) do
    settings = Wallboard.Settings.get()

    case authorize(conn, settings) do
      :ok ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(200, Ingest.codex_upload_script(hub_url(settings), Ingest.token()))

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

  defp authorize(conn, settings) do
    given =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> t] -> String.trim(t)
        _ -> nil
      end

    cond do
      not settings.archive.enabled -> {:error, 404, "the archive is turned off on this board"}
      Ingest.valid_token?(given) -> :ok
      true -> {:error, 401, "missing or wrong ingest key"}
    end
  end

  defp read_all(conn, acc) do
    case read_body(conn, length: 8_000_000, read_timeout: 60_000) do
      {:ok, chunk, conn} -> finish([chunk | acc], conn)
      {:more, chunk, conn} -> check_size([chunk | acc], conn)
      {:error, _} -> {:error, 400, "could not read the upload"}
    end
  end

  defp check_size(acc, conn) do
    if IO.iodata_length(acc) > @max_upload,
      do: {:error, 413, "upload too large"},
      else: read_all(conn, acc)
  end

  defp finish(acc, conn), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), conn}
end
