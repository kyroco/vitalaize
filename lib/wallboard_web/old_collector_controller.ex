defmodule WallboardWeb.OldCollectorController do
  @moduledoc """
  Answers the calls the upload hooks of VitalAIze 0.2.0 make. The hub
  takes nothing that way any more: every call is refused in plain words,
  whoever makes it. Nothing it sent is looked at or kept, and nothing is
  noted about who called.

  For one release: the release after 0.3.0 takes this out.
  """

  use Phoenix.Controller, formats: []

  import Plug.Conn

  @refusal """
  This hub no longer takes uploads from the old collector (VitalAIze 0.2.0).
  Install the new collector on this machine: open the VitalAIze app, or run
  `vitalaize setup` in a terminal. It takes the old hooks out for you.
  """

  @doc "What an old upload call is told."
  def refusal, do: @refusal

  def refuse(conn, _params) do
    conn
    # What the call sent is not read here, so the connection ends with the answer.
    |> put_resp_header("connection", "close")
    |> put_resp_content_type("text/plain")
    |> send_resp(410, @refusal)
  end
end
