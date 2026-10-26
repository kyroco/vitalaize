defmodule Wallboard.Browser do
  @moduledoc """
  Draws a page in headless Chrome and reads back what a script measured on
  it, for the few things only a real layout shows: whether something fits,
  or is cut off, on the board's 1366 x 1024 canvas.
  """

  @mac "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

  @doc """
  The Chrome to draw with: CHROME when set, else the first one found. GitHub's
  Ubuntu and macOS runners come with Google Chrome.
  """
  def chrome do
    [System.get_env("CHROME"), @mac]
    |> Enum.concat(
      Enum.map(
        ~w(google-chrome google-chrome-stable chromium chromium-browser),
        &System.find_executable/1
      )
    )
    |> Enum.find(&(is_binary(&1) and &1 != "" and File.exists?(&1)))
  end

  @doc """
  Draws `body` with the default theme's colors (`theme` is "dark" or
  "light") and the board's own stylesheet, at 1366 x 1024, then runs
  `script`, a JavaScript expression whose value is turned into JSON and
  returned decoded.
  """
  def measure(body, script, theme \\ "dark") do
    css = File.read!(Application.app_dir(:wallboard, "priv/static/css/app.css"))
    vars = WallboardWeb.Layouts.theme_css(Wallboard.Settings.defaults().theme)

    page = """
    <!doctype html>
    <html data-theme="#{theme}"><head><meta charset="utf-8">
    <style>#{vars}</style><style>#{css}</style></head>
    <body>#{body}<pre id="measured"></pre>
    <script>document.getElementById("measured").textContent = JSON.stringify((() => #{script})());</script>
    </body></html>
    """

    file = Wallboard.Fixtures.tmp_path("board-layout") <> ".html"
    File.write!(file, page)

    try do
      {dom, 0} =
        System.cmd(
          chrome(),
          ~w(--headless=new --disable-gpu --no-sandbox --hide-scrollbars --no-first-run
             --window-size=1366,1024 --virtual-time-budget=2000 --dump-dom) ++ ["file://" <> file],
          stderr_to_stdout: false
        )

      [json] = Regex.run(~r{<pre id="measured">(.*?)</pre>}s, dom, capture: :all_but_first)

      json
      |> String.replace(["&lt;", "&gt;", "&amp;"], fn
        "&lt;" -> "<"
        "&gt;" -> ">"
        "&amp;" -> "&"
      end)
      |> Jason.decode!()
    after
      File.rm(file)
    end
  end
end
