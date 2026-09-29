defmodule Wallboard.Alerts do
  @moduledoc """
  Texts the board's owner when a Claude session newly needs them.

  It runs notify.applescript, which tells the Messages app on this Mac to send
  an iMessage from whatever Apple ID is signed in there. The message and the
  phone number go in as separate arguments, never pasted into the script.

  With no phone number in settings, alerts are off.
  """

  require Logger
  alias Wallboard.Cmd

  @doc "Sends one text per session that newly needs you. Returns right away."
  def needs_you([], _settings), do: :ok

  def needs_you(sessions, settings) do
    case settings.alerts.phone do
      nil ->
        :ok

      phone ->
        for session <- sessions do
          text = message(session)

          Task.Supervisor.start_child(Wallboard.TaskSupervisor, fn ->
            case Cmd.run("osascript", [script_path(), text, phone, via(settings)],
                   timeout: 30_000
                 ) do
              {:ok, _} ->
                Logger.info("Texted: #{session.name} needs you")

              {:error, reason} ->
                Logger.warning("Could not send the text for #{session.name}: #{reason}")
            end
          end)
        end

        :ok
    end
  end

  @doc "The text message for one session."
  def message(session) do
    why = session.why |> to_string() |> String.slice(0, 240)
    "Wallboard: #{session.name} worker needs you. #{why}"
  end

  @doc ~S(How to send: "SMS" for a plain text, anything else means iMessage.)
  def via(settings) do
    case settings.alerts[:via] |> to_string() |> String.downcase() do
      "sms" -> "SMS"
      _ -> "iMessage"
    end
  end

  def script_path, do: Application.app_dir(:wallboard, "priv/notify.applescript")
end
