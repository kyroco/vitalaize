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

  # The bytes that would cross the network. Encoding also proves every
  # number fits its field.
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

  # Every item of one kind, in order.
  defp items(events, kind) do
    for event <- events, %{body: {^kind, body}} <- event.items, do: body
  end

  defp last(events, kind), do: events |> items(kind) |> List.last()

  defp lines(text), do: text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  # One real-shaped Claude reply line, with `fields` over the top.
  defp reply(fields \\ %{}, message \\ %{}) do
    message =
      Map.merge(
        %{
          "model" => "claude-opus-5-5",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
          "content" => []
        },
        message
      )

    %{
      "type" => "assistant",
      "requestId" => "req_1",
      "timestamp" => "2026-09-29T13:00:05Z",
      "cwd" => "/Users/r/projects/shop",
      "message" => message
    }
    |> Map.merge(fields)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  # What a hub holds after these events: the newest of each total, and each
  # request by its id.
  defp hub(events) do
    for event <- events, %{body: {kind, body}} <- event.items, reduce: %{} do
      held ->
        case {kind, body} do
          {:request, r} -> Map.put(held, {event.file, :request, r.request_id}, r)
          {:tool, t} -> Map.put(held, {event.file, :tool, t.name}, t)
          _ -> Map.put(held, {event.file, kind}, body)
        end
    end
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
      first = Enum.find(lines(claude()), &(&1["type"] == "user"))["message"]["content"]
      last = Enum.find(lines(claude()), &(&1["type"] == "last-prompt"))["lastPrompt"]
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

    test "the session is announced first, before anything else about it" do
      # The fixture's first line is a title with no time on it.
      [first | _] = events(claude_ctx(), claude())

      assert [
               %Proto.Item{
                 body: {:started, %Proto.SessionStarted{tool: :CLAUDE, account: "work"}}
               },
               %Proto.Item{body: {:summary, %Proto.Summary{title: "Fix the login loop"}}}
             ] = first.items

      assert length(items(events(claude_ctx(), claude()), :started)) == 1
    end

    test "the numbers match what the hub's reader counts" do
      events = events(claude_ctx(), claude())
      tally = Transcript.read_lines(claude())
      refute Enum.any?(events, & &1.subagent)

      assert last(events, :changes) == %Proto.Changes{
               lines_added: 4,
               lines_removed: 1,
               files_touched: 2
             }

      tools = for t <- items(events, :tool), into: %{}, do: {t.name, {t.calls, t.errors}}
      assert tools["Bash"] == {1, 1}
      assert tools["Edit"] == {1, 0}
      assert map_size(tools) == 4

      counts = last(events, :counts)
      assert {counts.prompts, counts.turns, counts.turn_ms} == {2, 2, 15_000}
      assert {counts.compactions, counts.api_errors, counts.retries} == {1, 1, 1}
      assert {counts.api_ms, counts.tool_ms, counts.peak_context} == {9000, 2000, 44_108}
      assert {counts.korium.searches, counts.korium.search_hits} == {1, 1}

      # The second request's later line changes its tokens, so it replaces
      # the first.
      assert Enum.map(items(events, :request), &{&1.request_id, &1.output_tokens}) ==
               [{"req_011CTestOne", 310}, {"req_011CTestTwo", 120}, {"req_011CTestTwo", 145}]

      [one | _] = items(events, :request)
      assert one.cache_read_tokens == 41_000 and one.cache_write_1h_tokens == 2200
      assert_in_delta one.cost, Usage.cost(tally.requests["req_011CTestOne"], @prices), 1.0e-9
      assert_in_delta one.cost, 0.05031, 1.0e-9
      refute one.subagent
    end

    test "a helper agent's file gives numbers and no text of its own" do
      events = events(helper_ctx(), helper())
      wire = wire(events)
      for secret <- planted(helper()), do: refute(wire =~ secret, "#{secret} left the filter")

      assert events != [] and Enum.all?(events, & &1.subagent)
      kinds = for event <- events, item <- event.items, do: elem(item.body, 0)
      assert Enum.all?(kinds, &(&1 in [:request, :tool, :changes, :counts]))
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
        for %{"payload" => %{"item" => %{"type" => "UserMessage"} = item}} <- lines(codex()),
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

      [first | _] = items(events, :request)

      assert {first.input_tokens, first.cache_read_tokens, first.output_tokens} ==
               {5000, 15_000, 400}

      assert {first.model, first.effort} == {"gpt-6-astra", "xhigh"}
    end

    test "a helper's file is treated as one even when the caller does not say so" do
      [meta | rest] = lines(codex())
      spawn = %{"subagent" => %{"thread_spawn" => %{"parent_thread_id" => "parent-thread"}}}
      meta = put_in(meta, ["payload", "source"], spawn)
      text = Enum.map_join([meta | rest], &(Jason.encode!(&1) <> "\n"))

      # No `subagent: true` here. A Codex helper's "prompts" are written by
      # the model that started it.
      events = events(codex_ctx(), text)
      assert events != [] and Enum.all?(events, & &1.subagent)
      assert items(events, :summary) == [] and items(events, :started) == []
      assert Enum.all?(items(events, :request), & &1.subagent)
      refute wire(events) =~ "cart total"
    end

    test "a helper's file stays a helper's when a later header names no parent" do
      header = fn source ->
        %{type: "session_meta", payload: %{id: @codex_id, cwd: "/Users/r/shop", source: source}}
      end

      said = fn text ->
        item = %{type: "UserMessage", content: [%{type: "text", text: text}]}
        %{type: "event_msg", payload: %{type: "item_completed", item: item}}
      end

      # Seen in a real Codex helper file: the parent's own header copied in
      # as the second line.
      text =
        [
          header.(%{subagent: %{thread_spawn: %{parent_thread_id: "parent-thread"}}}),
          said.("PLANTED helper prompt one"),
          header.("vscode"),
          said.("PLANTED helper prompt two")
        ]
        |> Enum.map_join(&(Jason.encode!(&1) <> "\n"))

      events = events(codex_ctx(), text)
      assert events != [] and Enum.all?(events, & &1.subagent)
      assert items(events, :summary) == [] and items(events, :started) == []
      refute wire(events) =~ "PLANTED"
    end
  end

  describe "values shaped like names" do
    test "a path, a sentence, a key or an address is not a name" do
      secrets = [
        "/Users/r/notes/PLANTED-plan.txt",
        "my password is PLANTED",
        "sk-PLANTED-api03-KEY",
        "robert:PLANTED@db.internal.example/x",
        "PLANTED@example.test",
        "token:PLANTED",
        "git push PLANTED main"
      ]

      for secret <- secrets do
        tool = %{"type" => "tool_use", "id" => "t1", "name" => secret, "input" => %{}}

        line =
          reply(
            %{
              "effort" => secret,
              "version" => secret,
              "entrypoint" => secret,
              "gitBranch" => "x"
            },
            %{"model" => secret, "content" => [tool]}
          )

        events = events(claude_ctx(), line)
        assert [%Proto.Request{model: "", effort: ""}] = items(events, :request)
        assert items(events, :tool) == []

        assert %Proto.Summary{model: "", effort: "", version: "", entrypoint: ""} =
                 last(events, :summary)

        refute wire(events) =~ "PLANTED", "#{secret} left the filter"

        status = Filter.status(claude_ctx(), :needs, why: :permission, tool: secret)
        refute wire([status]) =~ "PLANTED", "#{secret} left in a status"
      end
    end

    test "a request with an odd id, or none, still leaves, under a hash of the id" do
      odd = reply(%{"requestId" => "has spaces PLANTED"})
      number = reply(%{"requestId" => 7})
      none = reply() |> Jason.decode!() |> Map.delete("requestId") |> Jason.encode!()

      ids =
        for line <- [odd, number, none <> "\n"] do
          events = events(claude_ctx(), line)

          assert [%Proto.Request{input_tokens: 10, request_id: "h-" <> hash}] =
                   items(events, :request)

          assert byte_size(hash) == 16
          refute wire(events) =~ "PLANTED"
          hash
        end

      assert length(Enum.uniq(ids)) == 3

      # Two replies with no id are two requests, not one replacing the other.
      later = String.replace(none, "13:00:05", "13:00:09")
      two = events(claude_ctx(), none <> "\n" <> later <> "\n") |> items(:request)
      assert [%Proto.Request{request_id: a}, %Proto.Request{request_id: b}] = two
      assert a != b
      # The same id always gives the same hash.
      assert [%Proto.Request{request_id: "h-" <> again}] =
               items(events(claude_ctx(), odd), :request)

      assert again == hd(ids)
    end

    test "no more than 200 different tool names leave one file" do
      text =
        Enum.map_join(1..250, fn n ->
          tool = %{"type" => "tool_use", "id" => "t#{n}", "name" => "Tool#{n}", "input" => %{}}
          reply(%{"requestId" => "req_#{n}"}, %{"content" => [tool]})
        end)

      names = events(claude_ctx(), text) |> items(:tool) |> Enum.map(& &1.name) |> Enum.uniq()
      assert length(names) == 200
    end

    test "only a pull request link on github.com leaves, with its own number and repo" do
      links = [
        {"https://github.com/acme/shop/pull/12", 999, "other/repo"},
        {"https://evil.example/PLANTED/words/pull/1", 1, "acme/shop"},
        {"https://github.com/acme/shop/pull/13?PLANTED=1", 13, "acme/shop"},
        {"http://github.com/acme/PLANTED/pull/14", 14, "acme/shop"}
      ]

      text =
        Enum.map_join(links, fn {url, number, repo} ->
          Jason.encode!(%{type: "pr-link", prUrl: url, prNumber: number, prRepository: repo}) <>
            "\n"
        end)

      events = events(claude_ctx(), text)

      assert last(events, :summary).prs == [
               %Proto.PullRequest{
                 url: "https://github.com/acme/shop/pull/12",
                 number: 12,
                 repo: "acme/shop"
               }
             ]

      refute wire(events) =~ "PLANTED"

      many =
        Enum.map_join(1..80, fn n ->
          Jason.encode!(%{type: "pr-link", prUrl: "https://github.com/acme/shop/pull/#{n}"}) <>
            "\n"
        end)

      assert length(last(events(claude_ctx(), many), :summary).prs) == 50
    end
  end

  describe "allowed text" do
    test "text that does not show cannot ride along, whatever its size" do
      # Invisible "tag" letters: each stands for one ASCII letter, and a
      # whole run of them counts as part of the letter before it.
      hidden =
        for <<c <- String.duplicate("PLANTED SECRET ", 2000)>>,
          into: "",
          do: <<0xE0000 + c::utf8>>

      assert String.length("ok" <> hidden) == 2

      text =
        [
          %{type: "custom-title", customTitle: "Title" <> hidden},
          %{type: "last-prompt", lastPrompt: "Do it" <> hidden},
          %{
            type: "user",
            timestamp: "2026-09-29T13:00:00Z",
            cwd: "/Users/r/shop" <> hidden,
            gitBranch: "main" <> hidden,
            message: %{role: "user", content: "First" <> hidden}
          }
        ]
        |> Enum.map_join(&(Jason.encode!(&1) <> "\n"))

      events = events(Map.delete(claude_ctx(), :repo), text)

      assert %Proto.Summary{
               title: "Title",
               last_prompt: "Do it",
               first_prompt: "First",
               folder: "/Users/r/shop",
               branch: "main"
             } = last(events, :summary)

      assert byte_size(wire(events)) < 2000
    end

    test "control characters are taken out and long text is cut by size" do
      title =
        "Fix" <>
          <<0>> <>
          " the\e[31m login\n" <>
          <<0x202E::utf8>> <> "loop" <> <<0x200B::utf8, 0x3164::utf8, 0x034F::utf8>>

      long = String.duplicate("é", 5000)

      text =
        [
          %{type: "custom-title", customTitle: title},
          %{
            type: "user",
            cwd: "/" <> long,
            gitBranch: long,
            message: %{role: "user", content: "x"}
          }
        ]
        |> Enum.map_join(&(Jason.encode!(&1) <> "\n"))

      summary = last(events(claude_ctx(), text), :summary)
      assert summary.title == "Fix the[31m login loop"
      assert String.length(summary.folder) == 500 and byte_size(summary.folder) <= 2000
      assert String.length(summary.branch) == 200
      assert summary.repo == ""
    end

    test "the repo is asked only for a whole folder path, and a failed lookup is no repo" do
      for cwd <- ["", "relative/path", "~nouser/x", <<0>>, "/Users/r/other"] do
        line = reply(%{"cwd" => cwd})
        # claude_ctx's lookup knows one folder and raises on any other.
        assert last(events(claude_ctx(), line), :summary).repo == ""
        thrower = %{claude_ctx() | repo: fn _ -> throw(:no) end}
        assert last(events(thrower, line), :summary).repo == ""
        assert last(events(Map.delete(claude_ctx(), :repo), line), :summary).repo == ""
      end
    end
  end

  describe "numbers" do
    test "numbers too big for a message, or below zero, are held to what fits" do
      huge = String.duplicate("9", 400)

      text =
        [
          ~s({"type":"assistant","requestId":"req_big","timestamp":"2026-09-29T13:00:05Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":#{huge},"output_tokens":18446744073709551616,"cache_read_input_tokens":-5}}}),
          ~s({"type":"assistant","requestId":"req_neg","timestamp":"2026-09-29T13:00:06Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":-1000000,"output_tokens":3}}}),
          ~s({"type":"system","subtype":"turn_duration","durationMs":99999999999999999999999}),
          ~s({"type":"cost-state","totalAPIDuration":1.0e300,"totalToolDuration":-4}),
          ~s({"type":"pr-link","prUrl":"https://github.com/acme/shop/pull/7","prNumber":99999999999999999999999})
        ]
        |> Enum.map_join(&(&1 <> "\n"))

      events = events(claude_ctx(), text)
      assert byte_size(wire(events)) > 0

      max = 0xFFFFFFFFFFFFFFFF
      [big, negative] = items(events, :request)
      assert {big.input_tokens, big.output_tokens, big.cache_read_tokens} == {max, max, 0}
      assert big.cost >= 0.0
      assert {negative.input_tokens, negative.output_tokens} == {0, 3}
      assert_in_delta negative.cost, 3 * 25.0 / 1_000_000, 1.0e-12

      counts = last(events, :counts)

      assert {counts.turn_ms, counts.api_ms, counts.tool_ms, counts.peak_context} ==
               {max, max, 0, max}

      assert [%Proto.PullRequest{number: 7}] = last(events, :summary).prs
    end

    test "prices that cannot be used give a cost of zero, not a crash" do
      ctx = %{claude_ctx() | prices: %{"claude-opus-5-5" => %{input: 5.0}}}

      assert [%Proto.Request{cost: +0.0, input_tokens: 10}] =
               items(events(ctx, reply()), :request)
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

    test "each line gives at most one event, just past that line, with that line's time" do
      for {ctx, text} <- [{claude_ctx(), claude()}, {codex_ctx(), codex()}] do
        {all, _} =
          text
          |> String.split("\n", trim: true)
          |> Enum.reduce({[], Filter.new(ctx)}, fn line, {all, state} ->
            {events, state} = Filter.read(state, line <> "\n")
            assert length(events) <= 1

            for event <- events do
              assert event.position == Filter.position(state)
              assert event.session_id == ctx.session_id and event.file == ctx.file

              with {:ok, time, _} <- DateTime.from_iso8601(Jason.decode!(line)["timestamp"] || "") do
                assert event.at == DateTime.to_unix(time)
              end
            end

            {all ++ events, state}
          end)

        assert all == events(ctx, text)
      end
    end

    test "a stream cut anywhere and resumed by position leaves the hub with everything" do
      for {ctx, text} <- [{claude_ctx(), claude()}, {codex_ctx(), codex()}] do
        all = events(ctx, text)
        # Lines here give several items each; they must arrive together.
        assert Enum.any?(all, &(length(&1.items) > 1))

        for cut <- 0..length(all) do
          got = Enum.take(all, cut)
          resume = got |> Enum.map(& &1.position) |> Enum.max(fn -> 0 end)
          # The collector reads the file again and sends what is past it.
          again = Enum.filter(events(ctx, text), &(&1.position > resume))
          assert hub(got ++ again) == hub(all)
        end

        # A repeat changes nothing.
        assert hub(all ++ all) == hub(all)
      end
    end

    test "a reply written as several lines sends its request once" do
      text = reply() <> reply(%{"timestamp" => "2026-09-29T13:00:09Z"})
      assert [%Proto.Request{request_id: "req_1"}] = items(events(claude_ctx(), text), :request)
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

    test "a session id or file name that could not be sent as given is refused" do
      assert_raise ArgumentError, fn -> Filter.new(%{claude_ctx() | session_id: "has = sign"}) end
      assert_raise ArgumentError, fn -> Filter.new(%{claude_ctx() | session_id: ""}) end
      assert_raise ArgumentError, fn -> Filter.new(%{claude_ctx() | file: ""}) end
      assert_raise ArgumentError, fn -> Filter.new(%{claude_ctx() | file: " padded.jsonl"}) end

      long = String.duplicate("a", 2000) <> ".jsonl"
      assert_raise ArgumentError, fn -> Filter.new(%{claude_ctx() | file: long}) end
      assert_raise ArgumentError, fn -> Filter.status(%{session_id: "a b"}, :idle) end
    end
  end

  describe "live status" do
    test "says the kind of wait, never its words" do
      ctx = claude_ctx()
      at = ~U[2026-09-29 13:05:00Z]

      event =
        Filter.status(ctx, :needs, why: "permission prompt", tool: "Bash", since: at, at: at)

      assert event.session_id == @claude_id and event.file == "" and event.position == 0

      assert event.items == [
               %Proto.Item{
                 body:
                   {:status,
                    %Proto.Status{
                      state: :WAITING,
                      why: :PERMISSION,
                      tool: "Bash",
                      since: DateTime.to_unix(at)
                    }}
               }
             ]

      question = "Should I use the key PLANTED_QUESTION_SECRET for the deploy?"
      command = "curl -H 'X-Key: PLANTED_COMMAND_SECRET' https://example.com"
      event = Filter.status(ctx, :waiting, why: question, tool: command)
      assert %Proto.Status{state: :WAITING, why: :OTHER, tool: ""} = last([event], :status)
      refute wire([event]) =~ "PLANTED"

      assert %Proto.Status{why: :QUESTION} =
               last([Filter.status(ctx, :needs, why: :question)], :status)

      assert %Proto.Status{why: :WHY_UNKNOWN} = last([Filter.status(ctx, :needs)], :status)

      assert %Proto.Status{state: :WORKING, why: :WHY_UNKNOWN, tool: ""} =
               last([Filter.status(ctx, :working, why: :question, tool: "Bash")], :status)

      assert %Proto.Status{state: :IDLE} = last([Filter.status(ctx, :idle)], :status)
    end

    test "a session's end and a collector's hello" do
      at = ~U[2026-09-29 13:10:00Z]
      ended = Filter.ended(claude_ctx(), at)
      assert ended.items == [%Proto.Item{body: {:ended, %Proto.SessionEnded{}}}]
      assert ended.at == DateTime.to_unix(at)

      hello =
        Filter.hello(%{
          machine: "Robert's studio",
          os: "Darwin 27.0.0 arm64 (Apple Silicon)",
          version: "0.3.0+build.5 (dev)",
          folders: ["/Users/r/.claude", nil, "/Users/r/.codex"]
        })

      assert hello == %Proto.Hello{
               machine: "Robert's studio",
               os: "Darwin 27.0.0 arm64 (Apple Silicon)",
               version: "0.3.0+build.5 (dev)",
               folders: ["/Users/r/.claude", "/Users/r/.codex"]
             }
    end
  end
end
