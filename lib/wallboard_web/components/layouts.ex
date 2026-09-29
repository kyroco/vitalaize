defmodule WallboardWeb.Layouts do
  @moduledoc "The page shell: fonts, the theme from settings, and the scripts."
  use WallboardWeb, :html

  def root(assigns) do
    settings = Wallboard.Settings.get()
    assigns = assign(assigns, theme: settings.theme, brand: settings.brand)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta
          name="viewport"
          content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no"
        />
        <meta name="apple-mobile-web-app-capable" content="yes" />
        <meta name="mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-status-bar-style" content="default" />
        <meta name="apple-mobile-web-app-title" content={@brand.name} />
        <meta name="theme-color" content={@theme.page} />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <meta name="asset-version" content={asset_version()} />
        <title>{@brand.name} VitalAIze</title>
        <link :if={@theme.font_css_url} rel="stylesheet" href={@theme.font_css_url} />
        <style>
          <%= raw(theme_css(@theme)) %>
        </style>
        <%!-- The device's light or dark choice, set before the page draws so
             it never flashes the other one. --%>
        <script>
          try { var t = localStorage.getItem("wallboard-theme"); if (t === "dark" || t === "light") document.documentElement.dataset.theme = t; } catch (_) {}
        </script>
        <link rel="stylesheet" href={"/css/app.css?v=" <> asset_version()} />
        <script defer src="/vendor/phoenix.min.js">
        </script>
        <script defer src="/vendor/phoenix_live_view.min.js">
        </script>
        <script defer src={"/js/app.js?v=" <> asset_version()}>
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc """
  A short fingerprint of app.css and app.js, added to their addresses so a
  browser that kept an old copy (Safari on the iPad does) fetches the new one
  after an update.
  """
  def asset_version do
    case :persistent_term.get({__MODULE__, :asset_version}, nil) do
      nil ->
        version =
          [
            "css/app.css",
            "js/app.js",
            "images/claude.png",
            "images/codex-dark.png",
            "images/codex-light.png"
          ]
          |> Enum.map(&File.read!(Application.app_dir(:wallboard, Path.join("priv/static", &1))))
          |> then(&:crypto.hash(:md5, &1))
          |> Base.encode16(case: :lower)
          |> binary_part(0, 10)

        :persistent_term.put({__MODULE__, :asset_version}, version)
        version

      version ->
        version
    end
  end

  @color_keys ~w(page surface text text_body text_muted border border_strong track accent alert info info_light ok warn warn_deep)a

  @doc """
  The theme from settings as CSS variables, plus the body font files. The
  dark set applies when the device picked dark, or follows the device's own
  dark mode when it picked nothing.
  """
  def theme_css(theme) do
    vars = color_vars(theme)
    dark = color_vars(theme[:dark] || %{})

    faces =
      for face <- theme.font_faces || [] do
        "@font-face{font-family:'#{clean(face.family)}';src:url('/theme/fonts/#{URI.encode(face.file)}');" <>
          "font-weight:#{face[:weight] || 400};font-style:#{face[:style] || "normal"};font-display:swap}"
      end

    Enum.join(faces) <>
      ":root{color-scheme:light;" <>
      vars <>
      "--radius:#{clean(theme.radius)};--font-body:#{clean(theme.font_body)};--font-display:#{clean(theme.font_display)}}" <>
      ":root[data-theme=dark]{color-scheme:dark;#{dark}}" <>
      "@media (prefers-color-scheme: dark){:root:not([data-theme=light]){color-scheme:dark;#{dark}}}"
  end

  defp color_vars(theme) do
    for key <- @color_keys, value = theme[key], is_binary(value), into: "" do
      "--#{key |> Atom.to_string() |> String.replace("_", "-")}:#{clean(value)};"
    end
  end

  # Settings are the owner's own file, but a stray quote or brace should
  # break one value, not the whole page.
  defp clean(value), do: value |> to_string() |> String.replace(~r/[<>{};]/, "")
end
