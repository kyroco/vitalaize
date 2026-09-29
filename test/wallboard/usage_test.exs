defmodule Wallboard.Sources.UsageTest do
  use ExUnit.Case, async: true

  alias Wallboard.{Fixtures, Settings}
  alias Wallboard.Sources.Usage

  # Real transcript lines from this build's own session, with all
  # conversation and file text removed (see test/fixtures/README.md).
  @chunk Fixtures.read!("claude/transcript_trimmed.jsonl")
  @prices Settings.defaults().usage.prices

  defp stats(chunk \\ @chunk), do: Usage.parse_lines(Usage.empty_stats(), chunk)

  test "a reply split over several lines is counted once, by request id" do
    s = stats()
    assert map_size(s.requests) == 37
  end

  test "reads the latest model, effort and context size" do
    s = stats()
    assert s.last.model == "claude-opus-5-5"
    assert s.last.effort == "high"
    assert s.last.context == 114_120
    refute s.ended
  end

  test "costs the requests at the prices in settings, cache writes included" do
    total = stats().requests |> Map.values() |> Enum.map(&Usage.cost(&1, @prices)) |> Enum.sum()
    assert_in_delta total, 1.478614, 0.000001
  end

  test "counts lines added by edits and new files" do
    s = stats()
    assert {s.added, s.removed} == {264, 0}
  end

  test "reading in two pieces gives the same result as one" do
    lines = String.split(@chunk, "\n", trim: true)
    {a, b} = Enum.split(lines, 23)

    two =
      Usage.parse_lines(
        Usage.parse_lines(Usage.empty_stats(), Enum.join(a, "\n")),
        Enum.join(b, "\n")
      )

    one = stats()

    assert Map.take(two, [:requests, :added, :removed, :last]) ==
             Map.take(one, [:requests, :added, :removed, :last])
  end

  test "lines that are not replies or edits are skipped, even broken ones" do
    s = stats(~s({"type":"user","message":"hi"}\n{"type":"assistant","usage" broken\n))
    assert s.requests == %{}
  end

  test "a model id matches the longest price name it starts with" do
    assert Usage.price_for("claude-fable-5-1", @prices).label == "Fable 5.1"
    assert Usage.price_for("claude-fable-5", @prices).label == "Fable 5"
    assert Usage.price_for("claude-opus-4-8", @prices).label == "Opus 4"
    assert Usage.price_for("gpt-something", @prices) == nil
  end

  test "patch lines count + and - lines, and every line of a new file" do
    assert Usage.patch_lines(%{"structuredPatch" => [%{"lines" => [" a", "+b", "-c", "+d"]}]}) ==
             {2, 1}

    assert Usage.patch_lines(%{
             "type" => "create",
             "structuredPatch" => [],
             "content" => "a\nb\nc\n"
           }) == {3, 0}

    assert Usage.patch_lines(%{}) == {0, 0}
  end

  test "the trend compares active days and gives 14 daily values" do
    file = Map.merge(%{kind: :main, session_id: "s", meta: nil, mtime: 0}, stats())
    now = ~U[2026-09-29 03:00:00Z]
    t = Usage.trend([file], @prices, now)

    assert t.active_days == 1
    row = Enum.find(t.rows, &(&1.metric == :requests_per_day))
    assert row.current == 37.0
    assert row.previous == nil
    assert row.change == nil
    assert length(row.daily) == 14

    hit = Enum.find(t.rows, &(&1.metric == :cache_hit)).current
    assert hit > 90 and hit < 100
  end
end
