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

  ## A chat the Codex app copied in

  The Codex app can import chats from another tool (it took 44 Claude Code
  sessions at once on 2026-10-01, Codex 0.159.2). Each becomes a session
  file written in one go, so every line is stamped with the moment of the
  copy, within a second. Nobody is running it. What tells such a file from
  a session at work is each turn's own clock: `task_started` carries
  `started_at` and `task_complete` carries `completed_at`, in seconds since
  1970. Codex writes those lines as the turn starts and ends, so in a real
  session they are within a second of the line's stamp (measured), and in a
  copy they are hours or days before it.

  So a turn line whose own clock is more than a minute behind its stamp
  was copied in, and the lines stamped with it take the conversation's own
  time instead: the session's first and last times are when it happened,
  not when it was copied. `copy?/1` is true while the file holds nothing
  but the copy. Once someone carries the chat on in Codex, later lines have
  later stamps and it is a session like any other.

  A copied file is in the older shape (`history_mode` "legacy"): what the
  person typed is an `event_msg` `user_message`, a finished turn has no
  `duration_ms`, and there is no `token_usage_record` at all, only one
  `token_count` at the end whose `total_token_usage.total_tokens` is the
  whole chat's tokens with every part (input, cached, output) at 0. That
  total is kept as `total_tokens`. It cannot be split by kind, so a saved
  session of this shape has no token rows.
  """

  # A turn line whose own clock is this far behind its stamp was copied in.
  @copied_seconds 60
  # Lines stamped within this of a copied turn line belong to the same copy.
  @burst_seconds 2

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
      turn_started_at: nil,
      legacy: false,
      total_tokens: nil,
      # The stamp of the last line, and for a copied-in chat the stamp of
      # its last copied turn line and that turn's own time.
      stamped_at: nil,
      copied_at: nil,
      clock: nil
    })
  end

  @doc """
  True for a file that holds only a chat the Codex app copied in: nothing
  was written after the copy. See the module doc.
  """
  def copy?(%{copied_at: %DateTime{} = copied, stamped_at: %DateTime{} = stamped}),
    do: DateTime.diff(stamped, copied) <= @burst_seconds

  def copy?(_), do: false

  @doc """
  A Codex session's id as a card shows it: its last 8 characters. The ids
  start with the time, so sessions made close together share their first 8.
  """
  def short_id(id) when is_binary(id), do: String.slice(id, -8, 8)
  def short_id(_), do: ""

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

  defp entry(type, p, stamp, t) do
    t = copied(own_time(type, p), stamp, t)
    at = if near?(stamp, t.copied_at), do: t.clock, else: stamp
    t = %{t | stamped_at: stamp || t.stamped_at}

    # The first line comes before anything says whether the file is a copy,
    # so the session's times start with the line after it, which Codex
    # writes in the same moment. A copy's would be the moment of the copy.
    t =
      if type == "session_meta",
        do: t,
        else: %{t | first_at: t.first_at || at, last_at: at || t.last_at}

    entry_body(type, p, at, t)
  end

  # A turn's own time: when it started on the line that starts it, when it
  # ended on the line that ends it.
  defp own_time("event_msg", %{"type" => "task_started", "started_at" => s}), do: unix(s)

  defp own_time("event_msg", %{"type" => kind, "completed_at" => s})
       when kind in ["task_complete", "turn_aborted"],
       do: unix(s)

  defp own_time(_type, _p), do: nil

  # Notes a copied turn line: its stamp, and the turn's own time.
  defp copied(%DateTime{} = own, %DateTime{} = stamp, t) do
    if DateTime.diff(stamp, own) > @copied_seconds,
      do: %{t | copied_at: stamp, clock: own},
      else: t
  end

  defp copied(_own, _stamp, t), do: t

  defp near?(%DateTime{} = a, %DateTime{} = b), do: abs(DateTime.diff(a, b)) <= @burst_seconds
  defp near?(_, _), do: false

  defp unix(s) when is_integer(s) do
    case DateTime.from_unix(s) do
      {:ok, at} -> at
      _ -> nil
    end
  end

  defp unix(_), do: nil

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
        context_window: int_or_nil(p["context_window"]) || t.context_window,
        legacy: p["history_mode"] == "legacy"
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
    do: %{t | running: false, turns: t.turns + 1, turn_ms: t.turn_ms + turn_ms(p)}

  defp event("turn_aborted", p, _at, t),
    do: %{
      t
      | running: false,
        turns: t.turns + 1,
        aborted: t.aborted + 1,
        turn_ms: t.turn_ms + turn_ms(p)
    }

  # The older shape writes what the person typed as a line of its own.
  defp event("user_message", %{"message" => text}, _at, %{legacy: true} = t)
       when is_binary(text),
       do: prompt(t, String.trim(text))

  defp event("token_count", p, _at, t) do
    info = if is_map(p["info"]), do: p["info"], else: %{}
    last = dig(info, ["last_token_usage", "input_tokens"])
    used = dig(p, ["rate_limits", "primary", "used_percent"])

    %{
      t
      | context_window: int_or_nil(info["model_context_window"]) || t.context_window,
        last_context: int_or_nil(last) || t.last_context,
        plan_used: if(is_number(used), do: used, else: t.plan_used),
        total_tokens: positive(dig(info, ["total_token_usage", "total_tokens"])) || t.total_tokens
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

    prompt(t, text)
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

  defp prompt(t, ""), do: t

  defp prompt(t, text) do
    %{
      t
      | prompts: t.prompts + 1,
        first_prompt: t.first_prompt || clip(text),
        last_prompt: clip(text)
    }
  end

  # How long a turn ran. The older shape gives its start and end instead.
  defp turn_ms(%{"duration_ms" => ms}) when is_integer(ms), do: ms

  defp turn_ms(%{"started_at" => from, "completed_at" => to})
       when is_integer(from) and is_integer(to) and to > from,
       do: (to - from) * 1000

  defp turn_ms(_), do: 0

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
  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil
end
