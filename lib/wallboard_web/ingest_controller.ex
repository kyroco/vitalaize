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
