defmodule Wallboard.CollectorFilterTest do
  use ExUnit.Case, async: true

  alias Wallboard.Archive.{CodexTranscript, Transcript}
  alias Wallboard.Collector.{Filter, Proto}
  alias Wallboard.Fixtures
  alias Wallboard.Sources.Usage

  @claude_id "d299768e-2531-4395-a7ec-bf457e22c263"
  @codex_id "01a0c9db-3044-75f0-99fe-345bf658a60b"
  @prices %{"claude-opus-5-5" => %{input: 5.0, output: 25.0, cache_read: 0.5}}

  defp claude_ctx do
    %{
      tool: :claude,
      session_id: @claude_id,
      file: @claude_id <> ".jsonl",
      account: "work",
      prices: @prices,
      repo: fn "/Users/r/projects/shop" -> "acme/shop" end
    }
  end

  defp helper_ctx do
    Map.merge(claude_ctx(), %{file: @claude_id <> "/subagents/agent-a1.jsonl", subagent: true})
  end

  defp codex_ctx do
    %{
      tool: :codex,
      session_id: @codex_id,
      file: "2026/09/29/rollout-2026-09-29T14-00-00-" <> @codex_id <> ".jsonl",
      title: "Cart total with a coupon",
      repo: fn _ -> nil end
    }
  end

  defp events(ctx, text) do
    {events, _} = ctx |> Filter.new() |> Filter.read(text)
    events
  end

  defp claude, do: Fixtures.read!("collector/claude_session.jsonl")
  defp helper, do: Fixtures.read!("collector/claude_subagent.jsonl")
  defp codex, do: Fixtures.read!("collector/codex_rollout.jsonl")

  # The bytes that would cross the network.
  defp wire(events) do
    Enum.map_join(events, &Proto.FromCollector.encode(%Proto.FromCollector{body: {:event, &1}}))
  end

  # Every piece of text anywhere in the events.
  defp strings(events), do: events |> Enum.flat_map(&texts/1) |> Enum.uniq() |> Enum.sort()

  defp texts(s) when is_binary(s), do: if(s == "", do: [], else: [s])
  defp texts(%_{} = struct), do: struct |> Map.from_struct() |> Map.values() |> texts()
  defp texts(list) when is_list(list), do: Enum.flat_map(list, &texts/1)
  defp texts(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> texts()
  defp texts(_), do: []

  defp planted(text), do: Regex.scan(~r/PLANTED[A-Z_]+/, text) |> List.flatten() |> Enum.uniq()

  defp last(events, kind) do
    events |> Enum.filter(&match?({^kind, _}, &1.body)) |> List.last() |> then(&elem(&1.body, 1))
  end

  defp prompt(text, type) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["type"] == type))
  end

  describe "a Claude session" do
    test "none of the planted secrets leaves the filter" do
      secrets = planted(claude())
      assert length(secrets) >= 25

      events = events(claude_ctx(), claude())
      wire = wire(events)
      assert byte_size(wire) > 0
      for secret <- secrets, do: refute(wire =~ secret, "#{secret} left the filter")
    end

    test "the only text that leaves is the allowed text, clipped" do
      first = prompt(claude(), "user")["message"]["content"]
      last = prompt(claude(), "last-prompt")["lastPrompt"]
      assert String.length(first) > 300 and String.length(last) > 300

      assert strings(events(claude_ctx(), claude())) ==
               Enum.sort([
                 @claude_id,
                 @claude_id <> ".jsonl",
                 "work",
                 "Fix the login loop",
                 String.slice(first, 0, 299) <> "…",
                 String.slice(last, 0, 299) <> "…",
                 "/Users/r/projects/shop",
                 "fix/login-loop",
                 "acme/shop",
                 "https://github.com/acme/shop/pull/905",
                 "claude-opus-5-5",
                 "high",
                 "2.1.284",
                 "cli",
                 "req_011CTestOne",
                 "req_011CTestTwo",
                 "Bash",
                 "Edit",
                 "Write",
                 "mcp__claude_ai_korium__agent_search"
               ])
    end

    test "the numbers match what the hub's reader counts" do
      events = events(claude_ctx(), claude())
      tally = Transcript.read_lines(claude())

      assert %Proto.SessionStarted{tool: :CLAUDE, account: "work"} = last(events, :started)

      assert last(events, :changes) == %Proto.Changes{
               lines_added: 4,
               lines_removed: 1,
               files_touched: 2
             }

      tools = for %{body: {:tool, t}} <- events, into: %{}, do: {t.name, {t.calls, t.errors}}
      assert tools["Bash"] == {1, 1}
      assert tools["Edit"] == {1, 0}
      assert map_size(tools) == 4

      counts = last(events, :counts)
      assert {counts.prompts, counts.turns, counts.turn_ms} == {2, 2, 15_000}
      assert {counts.compactions, counts.api_errors, counts.retries} == {1, 1, 1}
      assert {counts.api_ms, counts.tool_ms, counts.peak_context} == {9000, 2000, 44_108}
      assert {counts.korium.searches, counts.korium.search_hits} == {1, 1}

      requests = for %{body: {:request, r}} <- events, do: r
      # The second request's later line replaces its first.
      assert Enum.map(requests, &{&1.request_id, &1.output_tokens}) ==
               [{"req_011CTestOne", 310}, {"req_011CTestTwo", 120}, {"req_011CTestTwo", 145}]

      [one | _] = requests
      assert one.cache_read_tokens == 41_000 and one.cache_write_1h_tokens == 2200
      assert_in_delta one.cost, Usage.cost(tally.requests["req_011CTestOne"], @prices), 1.0e-9
      assert_in_delta one.cost, 0.05031, 1.0e-9
      refute one.subagent
    end

    test "a helper agent's file gives numbers and no text of its own" do
      events = events(helper_ctx(), helper())
      wire = wire(events)
      for secret <- planted(helper()), do: refute(wire =~ secret, "#{secret} left the filter")

      assert events != []
      assert Enum.all?(events, &(elem(&1.body, 0) in [:request, :tool, :changes, :counts]))
      assert last(events, :request).subagent
      assert last(events, :tool) == %Proto.ToolTally{name: "Grep", calls: 1, errors: 0}

      assert strings(events) ==
               Enum.sort([
                 @claude_id,
                 helper_ctx().file,
                 "req_011CTestSub",
                 "claude-haiku-4-5-20251001",
                 "Grep"
               ])
    end
  end

  describe "a Codex session" do
    test "none of the planted secrets leaves the filter" do
      secrets = planted(codex())
      assert length(secrets) >= 15

      wire = wire(events(codex_ctx(), codex()))
      assert byte_size(wire) > 0
      for secret <- secrets, do: refute(wire =~ secret, "#{secret} left the filter")
    end

    test "the only text that leaves is the allowed text, clipped" do
      # Codex has no "last prompt" line, so each prompt is the last one until
      # the next: all three leave, clipped, each while it is the latest.
      [first, second, third] =
        for line <- String.split(codex(), "\n", trim: true),
            %{"payload" => %{"item" => %{"type" => "UserMessage"} = item}} <- [
              Jason.decode!(line)
            ],
            do: hd(item["content"])["text"]

      assert String.length(first) > 500 and String.length(second) > 500

      assert strings(events(codex_ctx(), codex())) ==
               Enum.sort([
                 @codex_id,
                 codex_ctx().file,
                 "Cart total with a coupon",
                 String.slice(first, 0, 499) <> "…",
                 String.slice(second, 0, 499) <> "…",
                 third,
                 "/Users/r/projects/shop",
                 "fix/cart-total",
                 "gpt-6-astra",
                 "xhigh",
                 "0.155.1",
                 "Codex Desktop",
                 "resp_test_1",
                 "resp_test_2",
                 "resp_test_3",
                 "shell",
                 "edit",
                 "mcp__korium__agent_search"
               ])
    end

    test "the numbers match what the hub's reader counts" do
      events = events(codex_ctx(), codex())
      tally = CodexTranscript.read_lines(codex())

      assert %Proto.SessionStarted{tool: :CODEX} = last(events, :started)

      assert last(events, :changes) == %Proto.Changes{
               lines_added: 4,
               lines_removed: 1,
               files_touched: 2
             }

      counts = last(events, :counts)
      assert {counts.prompts, counts.turns, counts.aborted} == {3, 3, 1}
      assert {counts.turn_ms, counts.context_window} == {13_000, 258_400}
      assert counts.peak_context == tally.peak_context

      [first | _] = for %{body: {:request, r}} <- events, do: r

      assert {first.input_tokens, first.cache_read_tokens, first.output_tokens} ==
               {5000, 15_000, 400}

      assert {first.model, first.effort} == {"gpt-6-astra", "xhigh"}
    end
  end

  describe "positions" do
    test "the same lines give the same events at the same positions" do
      for {ctx, text} <- [{claude_ctx(), claude()}, {codex_ctx(), codex()}] do
        once = events(ctx, text)
        assert events(ctx, text) == once

        # However the file's bytes arrive.
        {in_pieces, state} =
          for <<piece::binary-size(7) <- text <> String.duplicate(" ", 6)>>, reduce: {[], nil} do
            {events, state} ->
              {new, state} = Filter.read(state || Filter.new(ctx), piece)
              {events ++ new, state}
          end

        assert in_pieces == once
        assert Filter.position(state) == byte_size(text)
      end
    end

    test "every event sits just past the line it came from" do
      text = claude()
      events = events(claude_ctx(), text)

      ends =
        text
        |> :binary.matches("\n")
        |> MapSet.new(fn {at, 1} -> at + 1 end)

      assert Enum.all?(events, &(&1.position in ends))
      assert Enum.all?(events, &(&1.session_id == @claude_id and &1.file == claude_ctx().file))
      positions = Enum.map(events, & &1.position)
      assert positions == Enum.sort(positions)

      # The first prompt is the fixture's second line, written at 13:00:00.
      [line_one, line_two | _] = String.split(text, "\n")
      started = Enum.find(events, &match?({:started, _}, &1.body))
      assert started.position == byte_size(line_one) + byte_size(line_two) + 2
      assert started.at == DateTime.to_unix(~U[2026-09-29 13:00:00Z])
    end

    test "reading on from a resume point adds nothing the first read did not give" do
      text = claude()
      all = events(claude_ctx(), text)
      [head, tail] = :binary.split(text, "\n{\"type\":\"system\"")
      head = head <> "\n"

      {before, state} = claude_ctx() |> Filter.new() |> Filter.read(head)
      assert Filter.position(state) == byte_size(head)

      {rest, _} = Filter.read(state, "{\"type\":\"system\"" <> tail)
      assert before ++ rest == all
      assert Enum.all?(rest, &(&1.position > byte_size(head)))
    end

    test "half a line waits for its other half, and a bad line is skipped" do
      state = Filter.new(codex_ctx())
      [first, second | _] = String.split(codex(), "\n")

      {[], state} = Filter.read(state, String.slice(first, 0, 40))
      assert Filter.position(state) == 0

      # A line the Codex reader cannot take: its content is not a list.
      bad =
        ~s({"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":7}}})

      {events, state} =
        Filter.read(
          state,
          String.slice(first, 40..-1//1) <> "\n" <> bad <> "\n" <> second <> "\n"
        )

      assert Filter.position(state) == byte_size(first) + byte_size(bad) + byte_size(second) + 3
      assert %Proto.Summary{model: "gpt-6-astra"} = last(events, :summary)
    end
  end

  describe "live status" do
    test "says the kind of wait, never its words" do
      ctx = claude_ctx()
      at = ~U[2026-09-29 13:05:00Z]

      event =
        Filter.status(ctx, :needs, why: "permission prompt", tool: "Bash", since: at, at: at)

      assert event.session_id == @claude_id and event.file == "" and event.position == 0

      assert event.body ==
               {:status,
                %Proto.Status{
                  state: :WAITING,
                  why: :PERMISSION,
                  tool: "Bash",
                  since: DateTime.to_unix(at)
                }}

      question = "Should I use the key PLANTED_QUESTION_SECRET for the deploy?"
      command = "curl -H 'X-Key: PLANTED_COMMAND_SECRET' https://example.com"
      event = Filter.status(ctx, :waiting, why: question, tool: command)
      assert {:status, %Proto.Status{state: :WAITING, why: :OTHER, tool: ""}} = event.body
      refute wire([event]) =~ "PLANTED"

      assert {:status, %Proto.Status{why: :QUESTION}} =
               Filter.status(ctx, :needs, why: :question).body

      assert {:status, %Proto.Status{why: :WHY_UNKNOWN}} = Filter.status(ctx, :needs).body

      assert {:status, %Proto.Status{state: :WORKING, why: :WHY_UNKNOWN, tool: ""}} =
               Filter.status(ctx, :working, why: :question, tool: "Bash").body

      assert {:status, %Proto.Status{state: :IDLE}} = Filter.status(ctx, :idle).body
    end

    test "a session's end and a collector's hello" do
      at = ~U[2026-09-29 13:10:00Z]
      ended = Filter.ended(claude_ctx(), at)
      assert ended.body == {:ended, %Proto.SessionEnded{}}
      assert ended.at == DateTime.to_unix(at)

      hello =
        Filter.hello(%{
          machine: "Robert's studio",
          os: "macOS 15.6",
          version: "0.3.0",
          folders: ["/Users/r/.claude", nil, "/Users/r/.codex"]
        })

      assert hello == %Proto.Hello{
               machine: "Robert's studio",
               os: "macOS 15.6",
               version: "0.3.0",
               folders: ["/Users/r/.claude", "/Users/r/.codex"]
             }
    end
  end
end
