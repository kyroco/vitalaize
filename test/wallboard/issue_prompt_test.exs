defmodule Wallboard.IssuePromptTest do
  # The transcript readers keep the first prompt that names an issue, and
  # only its repository and number (issue #143).
  use ExUnit.Case, async: true

  alias Wallboard.Archive.{CodexTranscript, Transcript}

  defp claude(prompts) do
    prompts
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {text, i} ->
      Jason.encode!(%{
        type: "user",
        message: %{role: "user", content: text},
        timestamp: "2026-10-24T13:00:0#{i}Z"
      })
    end)
    |> then(&Transcript.read_lines/1)
  end

  defp codex(prompts) do
    prompts
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {text, i} ->
      Jason.encode!(%{
        type: "event_msg",
        payload: %{
          type: "item_completed",
          item: %{type: "UserMessage", content: [%{type: "text", text: text}]}
        },
        timestamp: "2026-10-24T13:00:0#{i}Z"
      })
    end)
    |> then(&CodexTranscript.read_lines/1)
  end

  for {reader, read} <- [{"Claude", :claude}, {"Codex", :codex}] do
    test "#{reader}: the first prompt that names an issue sets it, and a later one does not replace it" do
      t = unquote(read)(["hey", "look around first", "now work on #1418", "then #1300"])

      # Both are kept, in order: the first that is an issue wins.
      assert t.issues == [%{repo: nil, number: 1418}, %{repo: nil, number: 1300}]
      assert t.prompts == 4
    end

    test "#{reader}: a link names its repository" do
      t = unquote(read)(["https://github.com/acme/shop/issues/7 please"])
      assert t.issues == [%{repo: "acme/shop", number: 7}]
    end

    test "#{reader}: prompts that name no issue leave it empty" do
      assert unquote(read)(["hey", "fix the 3 failing tests"]).issues == []
    end

    test "#{reader}: at most three are kept, the first three named" do
      t = unquote(read)(["#1 #2", "#3 #4", "#1"])
      assert Enum.map(t.issues, & &1.number) == [1, 2, 3]
    end
  end

  # How Claude Code writes `/work-on #3586 dispatched` typed as a command.
  @command "<command-message>work-on</command-message>\n<command-name>/work-on</command-name>\n<command-args>#3586 dispatched</command-args>"

  test "a slash command's arguments name an issue, read by the transcript and usage readers" do
    line = Jason.encode!(%{type: "user", message: %{role: "user", content: @command}})

    assert Transcript.read_lines(line <> "\n" <> claude_line("then #12")).issues == [
             %{repo: nil, number: 3586},
             %{repo: nil, number: 12}
           ]

    usage = Wallboard.Sources.Usage.parse_lines(Wallboard.Sources.Usage.empty_stats(), line)
    assert usage.issues == [%{repo: nil, number: 3586}]
  end

  defp claude_line(text),
    do: Jason.encode!(%{type: "user", message: %{role: "user", content: text}})

  test "a Claude tool result or a line the app writes is not a prompt" do
    lines =
      [
        %{type: "user", message: %{role: "user", content: "<command-name>#12</command-name>"}},
        %{
          type: "user",
          message: %{role: "user", content: [%{type: "tool_result", content: "see #13"}]}
        }
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    assert Transcript.read_lines(lines).issues == []
  end
end
