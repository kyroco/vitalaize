defmodule WallboardWeb.DevicePage do
  @moduledoc """
  What a browser that is not approved yet sees, when the board asks for
  approval (see `WallboardWeb.Auth` and `Wallboard.Devices`): a code to
  match in the board's mailbox. The page looks again every few seconds by
  itself and opens the board once the owner approves it, so nobody types
  anything on the device.

  A plain page with no script: it has to work before the browser may open
  the board's own pages.
  """

  import Plug.Conn

  alias Wallboard.Devices

  # How often the waiting page looks again, in seconds.
  @every 3

  @doc "Answers a request from a browser that is not approved, and halts."
  def ask(conn) do
    address = conn.remote_ip |> :inet.ntoa() |> to_string()

    conn =
      if conn.params["ask"] == "again",
        do: delete_session(conn, :device_refused),
        else: conn

    cond do
      get_session(conn, :device_refused) ->
        page(conn, 403, :refused)

      true ->
        case Devices.status(get_session(conn, :device_ask), address) do
          {:approved, key} ->
            conn
            |> put_session(:device, key)
            |> delete_session(:device_ask)
            # A new cookie for a new right.
            |> configure_session(renew: true)
            |> open_board()

          {:pending, code} ->
            page(conn, 401, :waiting, code: code)

          :refused ->
            conn
            |> delete_session(:device_ask)
            |> put_session(:device_refused, true)
            |> page(403, :refused)

          :gone ->
            new_ask(conn, address)
        end
    end
  end

  defp new_ask(conn, address) do
    agent = conn |> get_req_header("user-agent") |> List.first()

    case Devices.ask(address, agent) do
      {:ok, id, code} -> conn |> put_session(:device_ask, id) |> page(401, :waiting, code: code)
      {:error, :busy} -> page(conn, 503, :busy)
    end
  end

  # Back to the board's front page: a path from the request could lead
  # anywhere.
  defp open_board(conn) do
    conn
    |> put_resp_header("location", "/")
    |> send_resp(303, "")
    |> halt()
  end

  # Drawn from the templates below, which escape what they show.
  defp page(conn, status, template, assigns \\ []) do
    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.put_view(html: __MODULE__.HTML)
    |> Phoenix.Controller.put_format("html")
    |> Phoenix.Controller.render(template, Keyword.put(assigns, :every, @every))
    |> halt()
  end

  defmodule HTML do
    @moduledoc false
    use WallboardWeb, :html

    def waiting(assigns) do
      ~H"""
      <.page refresh={@every}>
        <h1>Approve this device</h1>
        <p>
          On the Mac that runs the board, open the board, click the envelope at the top,
          and approve the request that shows this code:
        </p>
        <p class="code">{@code}</p>
        <p class="note">
          This page opens the board by itself once it is approved. The code lasts ten minutes.
        </p>
      </.page>
      """
    end

    def refused(assigns) do
      ~H"""
      <.page>
        <h1>This device was refused</h1>
        <p>The board's owner refused it in the mailbox.</p>
        <p><a href="/?ask=again">Ask again</a></p>
      </.page>
      """
    end

    def busy(assigns) do
      ~H"""
      <.page refresh={30}>
        <h1>The board is busy</h1>
        <p>
          Too many devices are asking to open it just now. This page tries again in half a minute.
        </p>
      </.page>
      """
    end

    attr :refresh, :integer, default: nil
    slot :inner_block, required: true

    defp page(assigns) do
      ~H"""
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <meta :if={@refresh} http-equiv="refresh" content={@refresh} />
          <title>VitalAIze</title>
          <style>
            body { font-family: -apple-system, system-ui, sans-serif; background: #111; color: #eee;
                   display: flex; align-items: center; justify-content: center; min-height: 100vh;
                   margin: 0; }
            main { max-width: 32rem; padding: 2rem; text-align: center; line-height: 1.5; }
            h1 { font-size: 1.6rem; margin: 0 0 1rem; }
            .code { font: 600 3.5rem ui-monospace, Menlo, monospace; letter-spacing: 0.1em;
                    margin: 1.5rem 0; }
            .note { color: #aaa; font-size: 0.95rem; }
            a { color: #7cc4ff; }
          </style>
        </head>
        <body>
          <main>{render_slot(@inner_block)}</main>
        </body>
      </html>
      """
    end
  end
end
