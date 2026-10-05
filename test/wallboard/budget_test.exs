defmodule Wallboard.BudgetTest do
  use ExUnit.Case, async: false

  alias Wallboard.{Settings, Store}
  alias Wallboard.Sources.Budget

  setup do
    start_supervised!({Store, path: ":memory:"})
    :ok
  end

  defp settings(budget, alerts \\ %{}),
    do: Settings.merge(Settings.defaults(), %{budget: budget, alerts: alerts})

  # Noon on a local day, as a DateTime: the board counts days in local time.
  defp noon(%Date{} = day) do
    {:ok, naive} = NaiveDateTime.new(day, ~T[12:00:00])
    [utc | _] = :calendar.local_time_to_universal_time_dst(NaiveDateTime.to_erl(naive))
    utc |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")
  end

  defp today, do: Wallboard.Archive.Trends.local_day(System.os_time(:second))

  defp put(id, tool, %DateTime{} = at, cost, tokens) do
    unix = DateTime.to_unix(at)

    :ok =
      Store.put_session(
        %{machine: "m", session_id: id, tool: tool, ended_at: unix},
        [
          %{
            machine: "m",
            session_id: id,
            request_id: id,
            at: unix,
            cost: cost,
            input_tokens: tokens,
            cache_read_tokens: 0,
            cache_write_tokens: 0,
            output_tokens: 0
          }
        ]
      )
  end

  # Records each alert instead of sending it.
  defp recorder do
    test = self()
    fn text, what, channels, _settings -> send(test, {:sent, text, what, channels}) end
  end

  test "Claude spend today over its limit is shown, and under it is not" do
    put("a", "claude", noon(today()), 162.4, 1000)

    assert [item] = Budget.over(settings(%{claude_dollars: 150}), noon(today()))
    assert item.key == :claude_dollars
    assert item.per == "day"
    assert item.total == 162.4
    assert Budget.describe(item) == "Claude spend today $162 of $150"

    assert Budget.alert_text(item) ==
             "VitalAIze: Claude spend today passed your $150 limit ($162 so far)."

    assert Budget.over(settings(%{claude_dollars: 200}), noon(today())) == []
  end

  test "a week counts from Monday, and a day only today" do
    monday = Date.beginning_of_week(today(), :monday)
    put("old", "claude", noon(Date.add(monday, -1)), 100.0, 1)
    put("mon", "claude", noon(monday), 5.0, 1)

    week = settings(%{claude_dollars: 4, claude_dollars_per: "week"})
    assert [%{total: 5.0, per: "week", since: ^monday}] = Budget.over(week, noon(today()))

    assert Budget.describe(hd(Budget.over(week, noon(today())))) ==
             "Claude spend this week $5 of $4"

    # The day before Monday is in last week, and in no day of this one.
    assert Budget.over(settings(%{claude_dollars: 6, claude_dollars_per: "week"}), noon(today())) ==
             []
  end

  test "Claude and Codex tokens are counted apart" do
    put("c", "claude", noon(today()), 1.0, 3_000)
    put("x", "codex", noon(today()), 0.0, 51_200_000)

    s = settings(%{claude_tokens: 5_000, codex_tokens: 50_000_000})
    assert [codex] = Budget.over(s, noon(today()))
    assert codex.key == :codex_tokens
    assert Budget.describe(codex) == "Codex tokens today 51,200,000 of 50,000,000"

    assert [_, _] =
             Budget.over(settings(%{claude_tokens: 2_000, codex_tokens: 1}), noon(today()))
  end

  test "each limit alerts once in its period and at its amount" do
    put("a", "claude", noon(today()), 162.0, 1)
    s = settings(%{claude_dollars: 150}, %{ntfy_topic: "t"})

    assert [_] = Budget.check(s, noon(today()), recorder())

    assert_received {:sent, "VitalAIze: Claude spend today passed" <> _, "budget, Claude spend",
                     [:ntfy]}

    # Polled again, or after a restart: the database remembers.
    assert [_] = Budget.check(s, noon(today()), recorder())
    refute_received {:sent, _, _, _}

    # Raised and still passed is new news; raised past the total is quiet.
    assert [_] =
             Budget.check(
               settings(%{claude_dollars: 160}, %{ntfy_topic: "t"}),
               noon(today()),
               recorder()
             )

    assert_received {:sent, _, _, _}

    assert [] =
             Budget.check(
               settings(%{claude_dollars: 170}, %{ntfy_topic: "t"}),
               noon(today()),
               recorder()
             )

    refute_received {:sent, _, _, _}

    # The same amount over a week is its own limit.
    week = settings(%{claude_dollars: 150, claude_dollars_per: "week"}, %{ntfy_topic: "t"})
    assert [_] = Budget.check(week, noon(today()), recorder())
    assert_received {:sent, "VitalAIze: Claude spend this week" <> _, _, _}

    # The next day starts fresh.
    tomorrow = Date.add(today(), 1)
    put("b", "claude", noon(tomorrow), 151.0, 1)
    assert [_] = Budget.check(s, noon(tomorrow), recorder())
    assert_received {:sent, _, _, _}
  end

  test "budget alerts go only on the channels switched on for them" do
    alerts = %{slack_webhook: "https://hooks.slack.com/x", ntfy_topic: "t"}

    assert Budget.channels(settings(%{}, alerts)) == [:slack, :ntfy]
    assert Budget.channels(settings(%{by_slack: false}, alerts)) == [:ntfy]
    # Needs you alerts still use every channel that is set up.
    assert Wallboard.Alerts.channels(settings(%{by_slack: false}, alerts)) == [:slack, :ntfy]
    # A channel switched on but not set up sends nothing.
    assert Budget.channels(settings(%{by_pushover: true}, alerts)) == [:slack, :ntfy]
  end

  test "with no limits, or the archive off, nothing shows and nothing is sent" do
    put("a", "claude", noon(today()), 1_000.0, 1_000_000_000)

    assert Budget.check(settings(%{}, %{ntfy_topic: "t"}), noon(today()), recorder()) == []

    off = Settings.merge(settings(%{claude_dollars: 1}), %{archive: %{enabled: false}})
    assert Budget.check(off, noon(today()), recorder()) == []
    refute_received {:sent, _, _, _}
  end

  describe "the settings page" do
    defp page(values) do
      base = Settings.defaults()

      fields =
        for {_, fs} <- Settings.editable(), {path, _, _, _, _} <- fs, into: %{} do
          value = Settings.current(base, path, nil)

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

    test "a limit takes a whole number written as people write amounts" do
      assert {:ok, over} =
               page(%{
                 "budget.claude_dollars" => "$1,500",
                 "budget.codex_tokens" => "50 000 000",
                 "budget.codex_tokens_per" => "week",
                 "budget.by_slack" => "false"
               })

      assert over.budget == %{
               claude_dollars: 1500,
               codex_tokens: 50_000_000,
               codex_tokens_per: "week",
               by_slack: false
             }
    end

    test "empty means no limit, and the defaults change nothing" do
      assert {:ok, over} = page(%{})
      refute Map.has_key?(over, :budget)
    end

    test "refuses a limit that is not a whole number above zero, and a period other than day or week" do
      assert {:error, errors} =
               page(%{
                 "budget.claude_dollars" => "12.50",
                 "budget.claude_tokens" => "0",
                 "budget.codex_tokens" => "lots",
                 "budget.claude_tokens_per" => "month"
               })

      assert Map.keys(errors) |> Enum.sort() ==
               ~w(budget.claude_dollars budget.claude_tokens budget.claude_tokens_per budget.codex_tokens)
    end
  end
end
