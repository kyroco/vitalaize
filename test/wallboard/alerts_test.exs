defmodule Wallboard.AlertsTest do
  use ExUnit.Case, async: true

  alias Wallboard.{Alerts, Settings}

  # Answers every request with the given status and sends what it got to the
  # test, so a real web request can be checked without the internet.
  defmodule Catcher do
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{test: test, status: status}) do
      {:ok, body, conn} = read_body(conn)
      send(test, {:got, conn.method, conn.request_path, conn.req_headers, body})
      send_resp(conn, status, "ok")
    end
  end

  defp catcher(status) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {Catcher, %{test: self(), status: status}},
        ip: :loopback,
        port: 0,
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  defp alerts(over), do: Settings.merge(Settings.defaults(), %{alerts: over})

  describe "which channels are on" do
    test "none by default" do
      assert Alerts.channels(Settings.defaults()) == []
    end

    test "each channel that is set, in a fixed order" do
      settings =
        alerts(%{
          phone: "+15550100",
          slack_webhook: "https://hooks.slack.com/services/T/B/X",
          ntfy_topic: "vitalaize-abc123",
          pushover_user: "u123",
          pushover_token: "a123"
        })

      assert Alerts.channels(settings) == [:messages, :slack, :ntfy, :pushover]
    end

    test "Pushover needs both its user key and its app token" do
      assert Alerts.channels(alerts(%{pushover_user: "u123"})) == []
      assert Alerts.channels(alerts(%{pushover_token: "a123"})) == []
    end

    test "a blank value counts as not set" do
      assert Alerts.channels(alerts(%{slack_webhook: "  ", ntfy_topic: ""})) == []
    end
  end

  describe "the requests" do
    test "Slack gets JSON text, with < > & escaped so a name cannot ping a channel" do
      settings = alerts(%{slack_webhook: "https://hooks.slack.com/services/T/B/X"})
      {url, _, type, body} = Alerts.request(:slack, "a <!channel> & b", settings)

      assert url == "https://hooks.slack.com/services/T/B/X"
      assert type == "application/json"
      assert Jason.decode!(body) == %{"text" => "a &lt;!channel&gt; &amp; b"}
    end

    test "ntfy posts plain text to the topic on ntfy.sh unless a server is set" do
      {url, headers, _, body} =
        Alerts.request(:ntfy, "shop needs you", alerts(%{ntfy_topic: "my-topic_1"}))

      assert url == "https://ntfy.sh/my-topic_1"
      assert {"Title", "VitalAIze"} in headers
      assert body == "shop needs you"

      {url, _, _, _} =
        Alerts.request(
          :ntfy,
          "x",
          alerts(%{ntfy_topic: "t", ntfy_server: "https://ntfy.example.com/"})
        )

      assert url == "https://ntfy.example.com/t"
    end

    test "Pushover gets a form with the token, user, title and message" do
      settings = alerts(%{pushover_user: "u123", pushover_token: "a123"})
      {url, _, type, body} = Alerts.request(:pushover, "shop & co needs you", settings)

      assert url == "https://api.pushover.net/1/messages.json"
      assert type == "application/x-www-form-urlencoded"

      assert URI.decode_query(body) == %{
               "token" => "a123",
               "user" => "u123",
               "title" => "VitalAIze",
               "message" => "shop & co needs you"
             }
    end
  end

  describe "sending" do
    test "Slack and ntfy really post, and a 2xx answer is success" do
      server = catcher(200)

      settings =
        alerts(%{
          slack_webhook: server <> "/services/T/B/X",
          ntfy_topic: "t1",
          ntfy_server: server
        })

      assert Alerts.deliver(:slack, "hello", settings) == :ok
      assert_receive {:got, "POST", "/services/T/B/X", headers, body}
      assert {"content-type", "application/json"} in headers
      assert Jason.decode!(body) == %{"text" => "hello"}

      assert Alerts.deliver(:ntfy, "héllo", settings) == :ok
      assert_receive {:got, "POST", "/t1", headers, "héllo"}
      assert {"title", "VitalAIze"} in headers
    end

    test "an error answer is a failure that names the status" do
      server = catcher(403)
      settings = alerts(%{ntfy_topic: "t1", ntfy_server: server})

      assert Alerts.deliver(:ntfy, "x", settings) == {:error, "the server answered 403"}
    end

    test "a server that cannot be reached fails without the address in the reason" do
      settings = alerts(%{slack_webhook: "http://127.0.0.1:1/services/HIDDENPATH"})

      assert {:error, reason} = Alerts.deliver(:slack, "x", settings)
      assert reason =~ "could not reach the server"
      refute reason =~ "HIDDENPATH"
    end
  end

  describe "the settings page" do
    defp page(values) do
      base = Settings.defaults()

      fields =
        for {_, fs} <- Settings.editable(), {path, _, _, _, _} <- fs, into: %{} do
          value = get_in(base, path)

          raw =
            cond do
              is_list(value) -> Enum.join(value, "\n")
              is_nil(value) -> ""
              true -> to_string(value)
            end

          {Enum.join(path, "."), raw}
        end

      Settings.check(Map.merge(fields, values), base)
    end

    test "saves good alert settings" do
      assert {:ok, over} =
               page(%{
                 "alerts.slack_webhook" => "https://hooks.slack.com/services/T/B/X",
                 "alerts.ntfy_topic" => "vitalaize-abc",
                 "alerts.pushover_user" => "u123",
                 "alerts.pushover_token" => "a123"
               })

      assert over.alerts.slack_webhook == "https://hooks.slack.com/services/T/B/X"
      assert over.alerts.ntfy_topic == "vitalaize-abc"
    end

    test "refuses a Slack address that is not https, and a topic with a slash" do
      assert {:error, errors} =
               page(%{
                 "alerts.slack_webhook" => "http://hooks.slack.com/x",
                 "alerts.ntfy_topic" => "a/b"
               })

      assert Map.has_key?(errors, "alerts.slack_webhook")
      assert Map.has_key?(errors, "alerts.ntfy_topic")
    end

    test "empty fields leave the channels off" do
      assert {:ok, over} = page(%{})
      refute Map.has_key?(over, :alerts)
    end
  end
end
