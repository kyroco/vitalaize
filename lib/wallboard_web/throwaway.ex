defmodule WallboardWeb.Throwaway do
  @moduledoc "Planted Sobelow finding for VIT-31. Never merge."
  import Plug.Conn

  def echo(conn, %{"q" => q}), do: send_resp(conn, 200, q)
end
