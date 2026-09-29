defmodule Wallboard.MiscTest do
  use ExUnit.Case, async: true

  alias Wallboard.{Alerts, Settings}
  alias Wallboard.Sources.NewRelic

  describe "settings" do
    test "a friend's file only needs what differs; the rest falls back" do
      merged =
        Settings.merge(Settings.defaults(), %{
          github: %{repo: "friend/app"},
          alerts: %{phone: "+15550100"}
        })

      assert merged.github.repo == "friend/app"
      assert merged.github.gate_workflow == "ci.yml"
      assert merged.alerts.phone == "+15550100"
      assert merged.theme.accent == "#e44456"
    end

    test "lists replace lists rather than merging" do
      merged = Settings.merge(Settings.defaults(), %{claude: %{config_dirs: ["~/.claude-work"]}})
      assert merged.claude.config_dirs == ["~/.claude-work"]
    end

    test "the example settings file is valid and matches the defaults" do
      {example, _} = Code.eval_file(Path.expand("../../settings.example.exs", __DIR__))

      assert Settings.merge(Settings.defaults(), example) ==
               Settings.defaults()
    end
  end

  test "the text message names the session and says why" do
    msg =
      Alerts.message(%{
        name: "shop-2043",
        account: "second-account",
        why: "A permission prompt is waiting for your approval"
      })

    assert msg ==
             "VitalAIze: shop-2043 needs you. A permission prompt is waiting for your approval"
  end

  test "alerts go by iMessage unless settings say SMS" do
    assert Alerts.via(Settings.defaults()) == "iMessage"
    assert Alerts.via(%{alerts: %{via: "sms"}}) == "SMS"
    assert Alerts.via(%{alerts: %{via: "SMS"}}) == "SMS"
    assert Alerts.via(%{alerts: %{}}) == "iMessage"
  end

  describe "New Relic" do
    test "the query asks for every check at once and escapes monitor names" do
      q =
        NewRelic.build_query(123, [%{id: "c0", name: "Heartbeat", monitor: "Shop's heartbeat"}])

      assert q =~ "account(id: 123)"
      assert q =~ "c0_latest: nrql"
      assert q =~ "c0_slots: nrql"
      assert q =~ "SELECT result, duration, timestamp FROM SyntheticCheck"
      assert q =~ "ORDER BY timestamp DESC LIMIT 1"
      assert q =~ ~S(monitorName = 'Shop\\'s heartbeat')
    end

    # Hand-written in the reply shape New Relic documents for NerdGraph NRQL
    # queries. Not captured: this session was not allowed to read the key.
    test "parses a NerdGraph reply (documented shape, not captured)" do
      body =
        Jason.encode!(%{
          data: %{
            actor: %{
              account: %{
                c0_latest: %{
                  results: [%{result: "SUCCESS", duration: 181.5, timestamp: 1_790_630_000_000}]
                },
                c0_stats: %{results: [%{uptime: 99.9, median: %{"50" => 180.2}}]},
                c0_slots: %{
                  results: [
                    %{beginTimeSeconds: 1, endTimeSeconds: 2, total: 3, failed: 0, avg: 170.0},
                    %{beginTimeSeconds: 2, endTimeSeconds: 3, total: 3, failed: 1, avg: 400.0},
                    %{beginTimeSeconds: 3, endTimeSeconds: 4, total: 0, failed: 0, avg: nil}
                  ]
                }
              },
              monitors: %{
                results: %{
                  entities: [%{name: "Heartbeat", monitoredUrl: "https://example.com/health"}]
                }
              }
            }
          }
        })

      {:ok, %{checks: [c]}} =
        NewRelic.parse(body, [%{id: "c0", name: "Heartbeat check", monitor: "Heartbeat"}])

      assert c.up
      assert c.last_at == DateTime.from_unix!(1_790_630_000_000, :millisecond)
      assert c.uptime == 99.9
      assert c.median_ms == 180.2
      assert c.url == "https://example.com/health"
      assert Enum.map(c.slots, & &1.result) == [:pass, :fail, :none]
    end

    test "a refused key comes back as words" do
      assert {:error, "New Relic: Invalid API key"} =
               NewRelic.parse(~s({"errors": [{"message": "Invalid API key"}]}), [])
    end
  end
end
