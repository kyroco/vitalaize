defmodule Wallboard.Archive.CodexTranscript do
  @moduledoc """
  Reads one Codex session file into the same tally the Claude reader builds
  (see `Wallboard.Archive.Transcript`), so both save into the same row.

  Codex writes each session to
  ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl. Every line
  is `{"timestamp", "type", "payload"}`. What they hold (checked against
  codex-cli 0.155.1, 2026-09-29):

    * `session_meta`: the thread id, folder, Codex version, who started it
      (`originator`: "Codex Desktop", "Claude Code", "codex_exec"), the git
      branch, and for a helper agent `source.subagent.thread_spawn` with its
      parent thread id and nickname
    * `turn_context`: the model and effort for the turn
    * `token_usage_record`: one model reply's tokens, by `response_id`. Its
      `input_tokens` include the cached ones, so fresh input is the
      difference
    * `event_msg` `task_started`, `task_complete` (with `duration_ms`) and
      `turn_aborted`: the turns, and whether one is running
    * `event_msg` `token_count`: the context window, the last reply's
      context, and how much of the plan's limit is used
    * `event_msg` `item_completed`: the person's messages (`UserMessage`),
      shell commands (`CommandExecution`, `failed` when they fail), file
      edits (`FileChange`, with a unified diff per file), MCP calls
      (`McpToolCall`, including Korium) and compactions
  """

  alias Wallboard.Archive.Transcript

  @doc "An empty tally: the Claude one plus what only Codex has."
  def empty do
    Map.merge(Transcript.empty(), %{
      thread_id: nil,
      parent_id: nil,
      nickname: nil,
      originator: nil,
      context_window: nil,
      last_context: nil,
      plan_used: nil,
      running: false,
      turn_started_at: nil
    })
  end

  @doc "Reads a whole file into a tally."
  def read_file(path) do
    path
    |> File.stream!(64 * 1024, [:read_ahead])
    |> Stream.transform("", fn chunk, rest ->
      [last | full] = :binary.split(rest <> chunk, "\n", [:global]) |> Enum.reverse()
      {Enum.reverse(full), last}
    end)
    |> Enum.reduce(empty(), &line/2)
  end

  @doc "Adds the lines of a chunk of text to a tally."
  def read_lines(tally \\ empty(), text) do
    text |> String.split("\n") |> Enum.reduce(tally, &line/2)
  end

  @doc """
  The thread id and parent thread id from a session file's first line,
  without reading the rest: {id, parent_id | nil, nickname | nil}, or nil.
  """
  def head(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]),
         first = IO.binread(io, :line),
         :ok <- File.close(io),
         true <- is_binary(first) do
      head_of(first)
    else
      _ -> nil
    end
  end

  @doc "The same as `head/1`, for a session file already in memory."
  def head_of(text) when is_binary(text) do
    [first | _] = :binary.split(text, "\n")

    case Jason.decode(first) do
      {:ok, %{"type" => "session_meta", "payload" => %{} = p}} ->
        spawn = spawn_of(p)
        {p["id"], spawn["parent_thread_id"], spawn["agent_nickname"] || spawn["agent_path"]}

      _ ->
        nil
    end
  end

  @doc "The thread id at the end of a session file's name."
  def id_from_path(path) do
    base = Path.basename(path, ".jsonl")
    if String.starts_with?(base, "rollout-"), do: String.slice(base, -36, 36), else: base
  end

  defp line("", t), do: t

  defp line(text, t) do
    case Jason.decode(text) do
      {:ok, %{"payload" => %{} = p} = e} -> entry(e["type"], p, time(e["timestamp"]), t)
      _ -> t
    end
  end

  defp entry(type, p, at, t) do
    t = %{t | first_at: t.first_at || at, last_at: at || t.last_at}
    entry_body(type, p, at, t)
  end

  defp entry_body("session_meta", p, _at, t) do
    spawn = spawn_of(p)
    git = if is_map(p["git"]), do: p["git"], else: %{}

    %{
      t
      | thread_id: p["id"],
        parent_id: spawn["parent_thread_id"],
        nickname: spawn["agent_nickname"] || spawn["agent_path"],
        originator: p["originator"],
        entrypoint: p["originator"],
        cwd: p["cwd"],
        version: p["cli_version"],
        git_branch: git["branch"],
        context_window: int_or_nil(p["context_window"]) || t.context_window
    }
  end

  defp entry_body("turn_context", p, _at, t),
    do: %{t | model: p["model"] || t.model, effort: p["effort"] || t.effort}

  defp entry_body("token_usage_record", %{"usage" => %{} = u} = p, at, t) do
    id = p["response_id"] || "#{p["turn_id"]}:#{map_size(t.requests)}"
    input = int(u["input_tokens"])
    cached = int(u["cached_input_tokens"])

    req = %{
      request_id: id,
      at: at,
      model: t.model,
      effort: t.effort,
      input: max(input - cached, 0),
      cache_read: cached,
      cache_write_5m: int(u["cache_write_input_tokens"]),
      cache_write_1h: 0,
      output: int(u["output_tokens"])
    }

    %{
      t
      | requests: Map.put(t.requests, id, req),
        last_request: id,
        peak_context: max(t.peak_context, input)
    }
  end

  defp entry_body("compacted", _p, _at, t), do: t

  defp entry_body("event_msg", %{"type" => kind} = p, at, t), do: event(kind, p, at, t)

  defp entry_body(_, _p, _at, t), do: t

  defp event("task_started", _p, at, t), do: %{t | running: true, turn_started_at: at}

  defp event("task_complete", p, _at, t),
    do: %{t | running: false, turns: t.turns + 1, turn_ms: t.turn_ms + int(p["duration_ms"])}

  defp event("turn_aborted", p, _at, t),
    do: %{
      t
      | running: false,
        turns: t.turns + 1,
        aborted: t.aborted + 1,
        turn_ms: t.turn_ms + int(p["duration_ms"])
    }

  defp event("token_count", p, _at, t) do
    info = if is_map(p["info"]), do: p["info"], else: %{}
    last = dig(info, ["last_token_usage", "input_tokens"])
    used = dig(p, ["rate_limits", "primary", "used_percent"])

    %{
      t
      | context_window: int_or_nil(info["model_context_window"]) || t.context_window,
        last_context: int_or_nil(last) || t.last_context,
        plan_used: if(is_number(used), do: used, else: t.plan_used)
    }
  end

  defp event("item_completed", %{"item" => %{"type" => kind} = item}, _at, t),
    do: item(kind, item, t)

  defp event(_, _p, _at, t), do: t

  defp item("UserMessage", item, t) do
    text =
      (item["content"] || [])
      |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
      |> Enum.map_join("\n", &(&1["text"] || ""))
      |> String.trim()

    if text == "" do
      t
    else
      %{
        t
        | prompts: t.prompts + 1,
          first_prompt: t.first_prompt || clip(text),
          last_prompt: clip(text)
      }
    end
  end

  defp item("CommandExecution", item, t) do
    t = tool(t, "shell", item["status"] == "failed")
    cmd = item["command"]
    cmd = if is_list(cmd), do: Enum.join(cmd, " "), else: to_string(cmd || "")
    if cmd =~ ~r/korium-cli\s+index/, do: korium_count(t, :index), else: t
  end

  defp item("FileChange", item, t) do
    changes = if is_map(item["changes"]), do: item["changes"], else: %{}
    t = tool(t, "edit", item["status"] == "failed")

    Enum.reduce(changes, t, fn {file, change}, t ->
      {added, removed} = diff_lines(change)

      %{
        t
        | files: MapSet.put(t.files, file),
          added: t.added + added,
          removed: t.removed + removed
      }
    end)
  end

  defp item("McpToolCall", item, t) do
    server = to_string(item["server"] || "")
    name = to_string(item["tool"] || "")
    result = if is_map(item["result"]), do: item["result"], else: %{}
    error? = item["status"] == "failed" or result["isError"] == true
    t = tool(t, "mcp__#{server}__#{name}", error?)

    if server =~ "korium" do
      text =
        (result["content"] || [])
        |> Enum.map_join("", &((is_map(&1) && &1["text"]) || ""))

      json =
        case Jason.decode(text) do
          {:ok, %{} = m} -> m
          _ -> nil
        end

      Transcript.korium_call(t, name, error?, json, text)
    else
      t
    end
  end

  defp item("ContextCompaction", _item, t), do: %{t | compactions: t.compactions + 1}
  defp item(_, _item, t), do: t

  @doc "Lines added and removed in one file change: a unified diff, or a new file's text."
  def diff_lines(%{"unified_diff" => diff}) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({0, 0}, fn
      "+++" <> _, acc -> acc
      "---" <> _, acc -> acc
      "+" <> _, {a, r} -> {a + 1, r}
      "-" <> _, {a, r} -> {a, r + 1}
      _, acc -> acc
    end)
  end

  def diff_lines(%{"content" => text}) when is_binary(text),
    do: {length(String.split(text, "\n", trim: true)), 0}

  def diff_lines(_), do: {0, 0}

  defp tool(t, name, error?) do
    tools =
      Map.update(t.tools, name, %{calls: 1, errors: if(error?, do: 1, else: 0)}, fn c ->
        %{c | calls: c.calls + 1, errors: c.errors + if(error?, do: 1, else: 0)}
      end)

    %{t | tools: tools}
  end

  # `source` is plain text ("vscode", "exec") for a session a person or app
  # started, and a map naming the parent thread for a helper agent.
  defp spawn_of(p) do
    case dig(p, ["source", "subagent", "thread_spawn"]) do
      %{} = spawn -> spawn
      _ -> %{}
    end
  end

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: dig(map[key], rest)
  defp dig(_, _), do: nil

  defp korium_count(t, key), do: %{t | korium: Map.update!(t.korium, key, &(&1 + 1))}

  defp clip(s) when is_binary(s) do
    s = String.trim(s)
    if String.length(s) > 500, do: String.slice(s, 0, 500) <> "…", else: s
  end

  defp time(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp time(_), do: nil

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0
  defp int_or_nil(n) when is_integer(n), do: n
  defp int_or_nil(_), do: nil
end
