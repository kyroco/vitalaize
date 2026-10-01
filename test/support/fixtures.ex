defmodule Wallboard.Fixtures do
  @moduledoc "Reads saved real command output from test/fixtures, and names temp folders."

  @dir Path.expand("../fixtures", __DIR__)

  def read!(name), do: File.read!(Path.join(@dir, name))

  @doc """
  A temp path starting with `prefix` that no other test, and no other test
  run on the same machine, uses. `unique_integer` starts over in every run,
  so the OS process id keeps two runs at once apart.
  """
  def tmp_path(prefix),
    do:
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

  @doc """
  The lines of a chat the Codex app copied in, shaped like the 44 it wrote
  on 2026-10-01 (Codex Desktop 0.159.2, `history_mode` "legacy"), with
  made-up text. Every line is stamped within a few milliseconds of
  `copied_at`; each turn's own clock says when the conversation happened.

  `turns` are `{started, ended}` in seconds since 1970. Each turn is a
  `task_started`, what the person typed, a few replies and a
  `task_complete`; one `token_count` with only a grand total comes before
  the last `task_complete`.
  """
  def codex_copy(id, copied_at, turns) do
    meta = %{
      type: "session_meta",
      payload: %{
        session_id: id,
        id: id,
        timestamp: DateTime.to_iso8601(copied_at),
        cwd: "/Users/r/projects/shop",
        originator: "Codex Desktop",
        cli_version: "0.159.2",
        source: "vscode",
        model_provider: "openai",
        history_mode: "legacy",
        git: %{branch: "main"}
      }
    }

    total = %{
      type: "event_msg",
      payload: %{
        type: "token_count",
        info: %{
          total_token_usage: %{
            input_tokens: 0,
            cached_input_tokens: 0,
            output_tokens: 0,
            total_tokens: 33_345
          },
          last_token_usage: %{input_tokens: 0, total_tokens: 33_345},
          model_context_window: nil
        },
        rate_limits: nil
      }
    }

    turns =
      turns
      |> Enum.with_index(1)
      |> Enum.map(fn {{started, ended}, n} ->
        last? = n == length(turns)

        [
          %{
            type: "event_msg",
            payload: %{type: "task_started", turn_id: "turn-#{n}", started_at: started}
          },
          %{
            type: "event_msg",
            payload: %{type: "user_message", message: "Acme cart question #{n}"}
          },
          %{
            type: "response_item",
            payload: %{
              type: "message",
              role: "assistant",
              content: [%{type: "output_text", text: "Acme answer #{n}"}]
            }
          },
          %{type: "event_msg", payload: %{type: "agent_message", message: "Acme answer #{n}"}}
        ] ++
          if(last?, do: [total], else: []) ++
          [
            %{
              type: "event_msg",
              payload: %{
                type: "task_complete",
                turn_id: "turn-#{n}",
                last_agent_message: nil,
                started_at: started,
                completed_at: ended
              }
            }
          ]
      end)

    [meta | List.flatten(turns)]
    |> Enum.with_index()
    |> Enum.map(fn {line, i} ->
      stamp = copied_at |> DateTime.add(i, :millisecond) |> DateTime.to_iso8601()
      Jason.encode!(Map.put(line, :timestamp, stamp))
    end)
  end
end
