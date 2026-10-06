defmodule Wallboard.Sources.Budget do
  @moduledoc """
  Limits on use, from the budget settings: Claude spend in dollars, Claude
  tokens and Codex tokens, each over a day or a week.

  Totals come from the archive, added up the way the Trends tab adds them
  (`Wallboard.Archive.Trends.sums/3`), so the two always agree and sessions
  from other machines count. Days are the board's local days, as on Trends,
  and a week starts on Monday.

  The archive saves a busy session on this machine once it has been quiet
  for `archive.settle_seconds`, so a long run with no pause is counted at
  its next pause. With the archive off there is nothing to add up, and no
  limit is checked.

  When a total passes its limit, the board shows it and one alert goes out
  on each budget channel that is switched on and set up under alerts. Each
  limit alerts once per period and amount: what has alerted is saved in the
  database, so a restart does not send it again, and raising a limit that
  was passed alerts again only when the new amount is passed.
  """

  alias Wallboard.Archive.Trends
  alias Wallboard.{Alerts, Store}

  # {setting, the total it is checked against, its name as people say it}
  @limits [
    {:claude_dollars, :cost, "Claude spend"},
    {:claude_tokens, :tokens, "Claude tokens"},
    {:codex_tokens, :codex_tokens, "Codex tokens"}
  ]

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(settings, _prev, memory, now) do
    {:ok, %{over: check(settings, now, &Alerts.send_text/4)}, memory}
  end

  def fingerprint(facts), do: facts

  # ---------------------------------------------------------------------------

  @doc """
  The limits passed in their current period, in settings order, each as
  %{key, label, per, limit, total, since}. Sends the alert for each one
  that has not alerted yet in its period at its amount, through
  `send.(text, what, channels, settings)`.
  """
  def check(settings, now, send) do
    over = if settings.archive.enabled, do: over(settings, now), else: []

    for item <- over, first_time?(item) do
      send.(alert_text(item), "budget, #{item.label}", channels(settings), settings)
    end

    over
  end

  @doc "The limits passed in their current period, without alerting."
  def over(settings, now) do
    today = Trends.local_day(DateTime.to_unix(now))
    budget = Map.get(settings, :budget, %{})

    set =
      for {key, total, label} <- @limits,
          limit = budget[key],
          is_number(limit) and limit > 0 do
        per = if budget[:"#{key}_per"] == "week", do: "week", else: "day"
        %{key: key, total_key: total, label: label, per: per, limit: limit}
      end

    # One sum for each period in use, not one for each limit.
    sums =
      set
      |> Enum.map(& &1.per)
      |> Enum.uniq()
      |> Map.new(fn per -> {per, Trends.sums(settings, period_start(per, today), today)} end)

    for item <- set, total = Map.fetch!(sums[item.per], item.total_key), total > item.limit do
      item
      |> Map.delete(:total_key)
      |> Map.merge(%{total: total, since: period_start(item.per, today)})
    end
  end

  @doc "The first day of the day or week that `today` is in. A week starts on Monday."
  def period_start("week", today), do: Date.beginning_of_week(today, :monday)
  def period_start(_day, today), do: today

  @doc "The alert channels that are set up and switched on for budget alerts."
  def channels(settings) do
    budget = Map.get(settings, :budget, %{})
    Enum.filter(Alerts.channels(settings), &(budget[:"by_#{&1}"] != false))
  end

  @doc ~S(The words for a passed limit: "Claude spend today $162.40 of $150".)
  def describe(item),
    do:
      "#{item.label} #{period(item.per)} #{amount(item.key, item.total)} of #{amount(item.key, item.limit)}"

  @doc "The alert text for a passed limit."
  def alert_text(item) do
    "VitalAIze: #{item.label} #{period(item.per)} passed your " <>
      "#{amount(item.key, item.limit)} limit (#{amount(item.key, item.total)} so far)."
  end

  defp period("week"), do: "this week"
  defp period(_day), do: "today"

  # A limit is whole dollars. What was spent shows to the cent, rounded up,
  # so a total just past a limit never reads as the limit itself. The
  # rounding to 6 places first keeps 1.1 * 100 = 110.00000000000001 at 110.
  defp amount(:claude_dollars, n) when is_integer(n), do: "$" <> Trends.thousands(n)

  defp amount(:claude_dollars, n) do
    cents = ceil(Float.round(n * 100, 6))

    "$#{Trends.thousands(div(cents, 100))}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp amount(_tokens, n), do: Trends.thousands(n)

  # Saved before the alert goes, so a send that fails or a crash part way
  # never sends it twice. A failed send is in the log.
  defp first_time?(item) do
    key = "budget_alert:#{item.key}:#{item.per}:#{item.since}:#{item.limit}"

    if Store.get_meta(key) do
      false
    else
      :ok = Store.put_meta(key, "1")
      true
    end
  end
end
