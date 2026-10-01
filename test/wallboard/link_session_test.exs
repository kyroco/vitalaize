defmodule Wallboard.LinkSessionTest do
  # The hub's picture of one remote session, from its events alone.
  use ExUnit.Case, async: true

  alias Wallboard.Archive.Transcript
  alias Wallboard.Collector.{Filter, Proto}
  alias Wallboard.Fixtures
  alias Wallboard.Link.Session
  alias Wallboard.Settings

  @id "d299768e-2531-4395-a7ec-bf457e22c263"
  @now ~U[2026-09-30 12:00:00Z]

  defp prices, do: Settings.defaults().usage.prices

  defp events(name, ctx) do
    {events, _} =
      ctx
      |> Map.merge(%{tool: :claude, session_id: @id, account: "main", prices: prices()})
      |> Filter.new()
      |> Filter.read(Fixtures.read!(name))

    events
  end

  defp main, do: events("collector/claude_session.jsonl", %{file: @id <> ".jsonl"})

  defp helper do
    events("collector/claude_subagent.jsonl", %{
      file: @id <> "/subagents/agent-a1.jsonl",
      subagent: true
    })
  end

  defp status(state, opts), do: Filter.status(%{session_id: @id}, state, opts)

  defp fold(events),
    do: Enum.reduce(events, Session.new("papa", @id), &Session.apply(&2, &1))

  test "the same events give the same session in any order, any number of times" do
    events =
      main() ++
        helper() ++
        [
          status(:working, at: @now),
          status(:needs, why: "input needed", question: "Deploy?", at: DateTime.add(@now, 5))
        ]

    whole = fold(events)

    for _ <- 1..20 do
      mixed = Enum.shuffle(events ++ Enum.take_random(events, 10))
      assert fold(mixed) == whole
    end

    assert Session.record(fold(Enum.reverse(events)), prices(), 0) ==
             Session.record(whole, prices(), 0)
  end

  test "its saved row adds up to what the transcript reader counts" do
    {row, requests} = Session.record(fold(main() ++ helper()), prices(), 7)

    ctx = %{prices: prices(), machine: "papa", session_id: @id, account: "main", path: nil}

    {read, read_requests} =
      Transcript.to_record(
        Transcript.read_lines(Fixtures.read!("collector/claude_session.jsonl")),
        [
          {Transcript.read_lines(Fixtures.read!("collector/claude_subagent.jsonl")), %{}}
        ],
        Map.merge(ctx, %{size: 0, mtime: 0, now: 7})
      )

    for key <- ~w(requests input_tokens output_tokens cache_read_tokens cache_write_tokens
          tool_calls tool_errors lines_added lines_removed prompts turns turn_ms subagents
          peak_context context_window api_ms tool_ms model effort title captured_at)a do
      assert {key, Map.fetch!(row, key)} == {key, Map.fetch!(read, key)}
    end

    assert_in_delta row.cost, read.cost, 1.0e-9
    assert row.source == "stream" and row.machine == "papa"
    assert length(requests) == length(read_requests)
    assert Enum.count(requests, & &1.subagent) == 1
    assert DateTime.from_unix!(row.started_at) == read.started_at
  end

  test "a session with nothing in it yet has no row, and no card until it says how it is" do
    assert Session.record(Session.new("papa", @id), prices(), 0) == nil
    assert Session.card(fold(main()), true, prices()) == nil

    card = Session.card(fold([status(:working, at: @now)]), true, prices())
    assert %{status: :working, name: "d299768e", machine: "papa", stale: false} = card
  end

  test "the card says why it waits: the question, the tool's name, or the kind of wait" do
    why = fn opts ->
      Session.card(fold(main() ++ [status(:needs, [at: @now] ++ opts)]), true, prices()).why
    end

    assert why.(why: "input needed", question: "Deploy to staging?") == "Deploy to staging?"
    assert why.(why: "input needed") == "It asked you a question"
    assert why.(why: :permission, tool: "Bash") == "Asks for your approval to use Bash"

    assert why.(why: "permission prompt") ==
             "A permission prompt is waiting for your approval"

    assert why.(why: "something new") == "Waiting on you"
  end

  test "the latest status wins, an end takes the card down, and a later status brings it back" do
    later = &DateTime.add(@now, &1)
    working = status(:working, at: @now)
    waiting = status(:needs, why: :question, at: later.(10), since: later.(8))
    ended = Filter.ended(%{session_id: @id}, later.(20))

    s = fold([waiting, working])
    assert Session.waiting?(s)
    assert Session.since(s) == DateTime.to_unix(later.(8))

    refute Session.live?(fold([working, waiting, ended]))
    refute Session.live?(fold([ended, waiting, working]))
    assert Session.card(fold([working, ended]), true, prices()) == nil

    back = fold([working, ended, status(:idle, at: later.(30))])
    assert Session.live?(back) and Session.state(back) == :idle
  end

  test "a card of a machine that is not connected is stale, and keeps its status" do
    s = fold(main() ++ [status(:working, at: @now)])
    down = DateTime.to_unix(@now) + 60
    card = Session.card(s, false, prices(), down)
    assert %{stale: true, status: :working} = card
    assert card.stale_since == DateTime.from_unix!(down)
    assert %{stale: false, stale_since: nil} = Session.card(s, true, prices())
  end

  test "a request sent again from further into its file replaces the earlier one" do
    event = fn position, output ->
      %Proto.Event{
        session_id: @id,
        file: "f.jsonl",
        position: position,
        at: 1,
        items: [
          %Proto.Item{body: {:started, %Proto.SessionStarted{tool: :CLAUDE}}},
          %Proto.Item{
            body: {:request, %Proto.Request{request_id: "r1", output_tokens: output, cost: 0.5}}
          }
        ]
      }
    end

    for events <- [[event.(10, 5), event.(20, 9)], [event.(20, 9), event.(10, 5)]] do
      {row, [request]} = Session.record(fold(events), prices(), 0)
      assert {row.requests, row.output_tokens, request.output_tokens} == {1, 9, 9}
    end
  end
end
