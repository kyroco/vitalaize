defmodule WallboardWeb.AssetController do
  @moduledoc "Serves the logo and font files named in settings."
  use Phoenix.Controller, formats: []
  import Plug.Conn

  @types %{".svg" => "image/svg+xml", ".png" => "image/png"}
  @font_types %{
    ".otf" => "font/otf",
    ".ttf" => "font/ttf",
    ".woff" => "font/woff",
    ".woff2" => "font/woff2"
  }

  def logo(conn, _params) do
    serve(conn, Wallboard.Settings.get().brand.logo, @types)
  end

  def font(conn, %{"file" => file}) do
    dir =
      Wallboard.Settings.get().theme.fonts_dir ||
        Application.app_dir(:wallboard, "priv/static/fonts")

    # Only a bare file name, so the address can never reach outside the folder.
    if Path.basename(file) == file,
      do: serve(conn, Path.join(Path.expand(dir), file), @font_types),
      else: send_resp(conn, 404, "")
  end

  defp serve(conn, nil, _types), do: send_resp(conn, 404, "")

  defp serve(conn, path, types) do
    with {:ok, type} <- Map.fetch(types, path |> Path.extname() |> String.downcase()),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
