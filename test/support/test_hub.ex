defmodule Wallboard.TestHub do
  @moduledoc """
  The endpoint's own parsing in front of the real router, without the rest
  of the endpoint (sessions, static files), which needs a server. `serve/1`
  runs it, or another plug, on a free local port.
  """

  use Plug.Builder
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug WallboardWeb.Router

  @doc "Serves `plug` on a free port on this machine only; returns its address."
  def serve(plug \\ __MODULE__) do
    {:ok, pid} = Bandit.start_link(plug: plug, ip: :loopback, port: 0, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end
end
