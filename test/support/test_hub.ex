defmodule Wallboard.TestHub do
  @moduledoc """
  The endpoint's own parsing in front of the real router, without the rest
  of the endpoint (sessions, static files), which needs a server. `serve/1`
  runs it, or another plug, on a free local port.
  """

  use Plug.Builder
  plug :parse_body
  plug WallboardWeb.Router

  defp parse_body(conn, opts), do: WallboardWeb.Endpoint.parse_body(conn, opts)

  @doc """
  Serves `plug` on a free port on this machine only; returns its address.
  Serving the hub starts its UploadGate too, for the test calling it.
  """
  def serve(plug \\ __MODULE__) do
    if plug == __MODULE__ and Process.whereis(Wallboard.Archive.UploadGate) == nil,
      do: ExUnit.Callbacks.start_supervised!(Wallboard.Archive.UploadGate)

    # HTTP/2 off, as on the board (Wallboard.Application.http_options/1).
    {:ok, pid} =
      Bandit.start_link(
        plug: plug,
        ip: :loopback,
        port: 0,
        startup_log: false,
        http_2_options: [enabled: false]
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end
end
