defmodule Wallboard.Alerts do
  @moduledoc """
  Tells the board's owner when a Claude or Codex session newly needs them.

  There are four ways to send, and every one that is set up in settings gets
  one alert each time a session starts waiting:

    * Messages: runs notify.applescript, which tells the Messages app on this
      Mac to send an iMessage (or SMS) from the Apple ID signed in there. The
      message and the phone number go in as separate arguments, never pasted
      into the script. Messages is a Mac app, so on Linux this is logged as
      not sent.
    * Slack: posts to an incoming webhook.
    * ntfy: posts to a topic on ntfy.sh (or your own ntfy server). Works on
      any phone with the ntfy app.
    * Pushover: posts to Pushover's message API.

  With none of them set up, alerts are off.

  A budget limit that is passed (see `Wallboard.Sources.Budget`) sends its
  alert the same way, on the channels its settings pick.
  """

  require Logger
  alias Wallboard.Cmd

  @ntfy_server "https://ntfy.sh"
  @pushover_url "https://api.pushover.net/1/messages.json"
  @title "VitalAIze"

  @doc "Sends one alert per session that newly needs you, on every channel. Returns right away."
  def needs_you([], _settings), do: :ok

  def needs_you(sessions, settings) do
    for session <- sessions do
      send_text(message(session), "#{session.name} needs you", channels(settings), settings)
    end

    :ok
  end

  @doc """
  Sends one text on each of `channels`, each in a task of its own, and logs
  how it went under `what`. Returns right away.
  """
  def send_text(text, what, channels, settings) do
    for channel <- channels do
      Task.Supervisor.start_child(Wallboard.TaskSupervisor, fn ->
        case deliver(channel, text, settings) do
          :ok ->
            Logger.info("Sent by #{name(channel)}: #{what}")

          {:error, reason} ->
            Logger.warning("Could not send by #{name(channel)} (#{what}): #{reason}")
        end
      end)
    end

    :ok
  end

  @doc "The channels that are set up in settings, in a fixed order."
  def channels(settings) do
    a = Map.get(settings, :alerts, %{})

    [
      {:messages, present?(a[:phone])},
      {:slack, present?(a[:slack_webhook])},
      {:ntfy, present?(a[:ntfy_topic])},
      {:pushover, present?(a[:pushover_user]) and present?(a[:pushover_token])}
    ]
    |> Enum.filter(fn {_, on?} -> on? end)
    |> Enum.map(fn {channel, _} -> channel end)
  end

  @doc "The alert text for one session."
  def message(session) do
    why = session.why |> to_string() |> String.slice(0, 240)
    "VitalAIze: #{session.name} needs you. #{why}"
  end

  @doc ~S(How Messages sends: "SMS" for a plain text, anything else means iMessage.)
  def via(settings) do
    case settings.alerts[:via] |> to_string() |> String.downcase() do
      "sms" -> "SMS"
      _ -> "iMessage"
    end
  end

  def script_path, do: Application.app_dir(:wallboard, "priv/notify.applescript")

  @doc """
  The web request for a channel that sends over the internet:
  {url, headers, content_type, body}. Kept apart from sending so tests can
  check it without the network.
  """
  def request(:slack, text, settings) do
    {settings.alerts.slack_webhook, [], "application/json",
     Jason.encode!(%{text: slack_escape(text)})}
  end

  def request(:ntfy, text, settings) do
    server =
      case settings.alerts[:ntfy_server] do
        server when is_binary(server) -> String.trim_trailing(server, "/")
        _ -> @ntfy_server
      end

    url = server <> "/" <> URI.encode(settings.alerts.ntfy_topic, &URI.char_unreserved?/1)
    {url, [{"Title", @title}, {"Tags", "bell"}], "text/plain; charset=utf-8", text}
  end

  def request(:pushover, text, settings) do
    body =
      URI.encode_query(%{
        token: settings.alerts.pushover_token,
        user: settings.alerts.pushover_user,
        title: @title,
        message: text
      })

    {@pushover_url, [], "application/x-www-form-urlencoded", body}
  end

  @doc "Sends one alert on one channel. Returns :ok or {:error, reason}."
  def deliver(:messages, text, settings) do
    case Cmd.run("osascript", [script_path(), text, settings.alerts.phone, via(settings)],
           timeout: 30_000
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def deliver(channel, text, settings) do
    {url, headers, type, body} = request(channel, text, settings)
    post(url, headers, type, body)
  end

  defp post(url, headers, type, body) do
    headers = for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}
    url = String.to_charlist(url)

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(
           :post,
           {url, headers, String.to_charlist(type), body},
           [timeout: 15_000, ssl: ssl],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
      {:ok, {{_, status, _}, _, _}} -> {:error, "the server answered #{status}"}
      # Only the error's kind: the address can hold a webhook secret or a
      # topic, and neither belongs in a log.
      {:error, reason} -> {:error, "could not reach the server (#{error_kind(reason)})"}
    end
  end

  defp error_kind({kind, _}) when is_atom(kind), do: kind
  defp error_kind(kind) when is_atom(kind), do: kind
  defp error_kind(_), do: "network error"

  # Slack reads <...> as a link or a mention such as <!channel>, so a session
  # name must not be able to ping a whole channel.
  defp slack_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc "The channel's name as people say it."
  def name(:messages), do: "Messages"
  def name(:slack), do: "Slack"
  def name(:ntfy), do: "ntfy"
  def name(:pushover), do: "Pushover"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
