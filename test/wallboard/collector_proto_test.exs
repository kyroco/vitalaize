defmodule Wallboard.CollectorProtoTest do
  use ExUnit.Case, async: true

  alias Wallboard.Collector.Proto

  # One of every kind of event, with no field left at its default.
  defp bodies do
    [
      started: %Proto.SessionStarted{tool: :CODEX, account: "work"},
      request: %Proto.Request{
        request_id: "req_1",
        model: "claude-opus-5-5",
        effort: "high",
        input_tokens: 12,
        output_tokens: 310,
        cache_read_tokens: 41_000,
        cache_write_5m_tokens: 5,
        cache_write_1h_tokens: 2200,
        cost: 0.05031,
        subagent: true
      },
      tool: %Proto.ToolTally{name: "Bash", calls: 7, errors: 2},
      changes: %Proto.Changes{lines_added: 40, lines_removed: 9, files_touched: 3},
      status: %Proto.Status{
        state: :WAITING,
        why: :PERMISSION,
        tool: "Bash",
        since: 1_790_000_000
      },
      summary: %Proto.Summary{
        title: "Fix the login loop",
        first_prompt: "The login page loops",
        last_prompt: "Run the tests again",
        folder: "/Users/r/projects/shop",
        branch: "fix/login-loop",
        repo: "acme/shop",
        prs: [
          %Proto.PullRequest{
            url: "https://github.com/acme/shop/pull/905",
            number: 905,
            repo: "acme/shop"
          }
        ],
        model: "claude-opus-5-5",
        effort: "high",
        version: "2.1.284",
        entrypoint: "cli"
      },
      ended: %Proto.SessionEnded{},
      counts: %Proto.Counts{
        prompts: 1,
        turns: 2,
        turn_ms: 3,
        api_ms: 4,
        tool_ms: 5,
        compactions: 6,
        api_errors: 7,
        retries: 8,
        aborted: 9,
        denials: 10,
        peak_context: 11,
        context_window: 12,
        korium: %Proto.Korium{
          searches: 1,
          search_hits: 2,
          saves: 3,
          save_errors: 4,
          code_searches: 5,
          code_hits: 6,
          index: 7,
          other: 8
        }
      }
    ]
  end

  defp from_collector do
    # Each kind alone, then all of them in one event, as one line can give.
    events =
      for items <- Enum.map(bodies(), &[&1]) ++ [bodies()] do
        {:event,
         %Proto.Event{
           session_id: "d299768e",
           file: "d299768e.jsonl",
           position: 4096,
           at: 1_790_000_000,
           subagent: true,
           items: Enum.map(items, &%Proto.Item{body: &1})
         }}
      end

    hello = %Proto.Hello{
      machine: "studio",
      os: "macOS 15.6",
      version: "0.3.0",
      folders: ["/Users/r/.claude", "/Users/r/.codex"]
    }

    [{:hello, hello}, {:ack, %Proto.Ack{id: 9}}] ++ events
  end

  defp from_hub do
    point = %Proto.ResumePoint{session_id: "d299768e", file: "d299768e.jsonl", position: 4096}

    [
      resume: %Proto.Resume{points: [point]},
      back_soon: %Proto.BackSoon{},
      disconnected: %Proto.Disconnected{},
      answer: %Proto.Answer{}
    ]
  end

  # The names in a message's oneof, from the schema itself.
  defp kinds(module) do
    for {_, field} <- module.__message_props__().field_props,
        field.oneof != nil,
        into: MapSet.new() do
      field.name_atom
    end
  end

  test "every collector message survives encoding and decoding" do
    for body <- from_collector() do
      message = %Proto.FromCollector{body: body}
      assert message |> Proto.FromCollector.encode() |> Proto.FromCollector.decode() == message
    end
  end

  test "every hub message survives encoding and decoding" do
    for {body, id} <- Enum.with_index(from_hub(), 1) do
      message = %Proto.FromHub{id: id, body: body}
      assert message |> Proto.FromHub.encode() |> Proto.FromHub.decode() == message
    end
  end

  test "the round trips above cover every message kind in the schema" do
    assert MapSet.new(from_collector(), &elem(&1, 0)) == kinds(Proto.FromCollector)
    assert MapSet.new(Keyword.keys(bodies())) == kinds(Proto.Item)
    assert MapSet.new(Keyword.keys(from_hub())) == kinds(Proto.FromHub)
  end

  test "the answer to a waiting agent is kept but empty" do
    assert Proto.Answer.__message_props__().field_props == %{}
  end
end
