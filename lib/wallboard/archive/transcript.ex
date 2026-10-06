defmodule Wallboard.Archive.Transcript do
  @moduledoc """
  Reads one Claude session in full, its transcript and its subagents', into
  the record the database keeps.

  What the transcript lines hold (checked against real ones, 2026-09-29):

    * a model reply (`"type":"assistant"`) carries its request id, model,
      effort and token counts, and the tool calls it made
    * a tool result (`"type":"user"`) carries the reply to one tool call,
      `is_error` when it failed, and `toolDenialKind` when a permission rule
      refused it
    * `system` lines with subtype `api_error` (with `retryAttempt`),
      `compact_boundary` and `turn_duration` (`durationMs`)
    * `custom-title`, `agent-name`, `ai-title`, `last-prompt` and `pr-link`
      lines, and a `cost-state` line with the session's API and tool time

  Korium replies are JSON text. A search is a hit when `result_count` is
  above zero, a code search when `results` is not empty, and a save worked
  when it was not an error.
  """

  alias Wallboard.Sources.Usage

  @doc "An empty tally for one file."
  def empty do
    %{
      first_at: nil,
      last_at: nil,
      cwd: nil,
      git_branch: nil,
      # Every branch seen, in the order first seen, with when: a session can
      # push one branch and end on another.
      branches: [],
      version: nil,
      entrypoint: nil,
      titles: %{},
      first_prompt: nil,
      last_prompt: nil,
      requests: %{},
      # The id of the request the latest reply line added or changed.
      last_request: nil,
      model: nil,
      effort: nil,
      peak_context: 0,
      prompts: 0,
      turns: 0,
      turn_ms: 0,
      cost_state: nil,
      compactions: 0,
      api_errors: 0,
      retries: 0,
      aborted: 0,
      tools: %{},
      pending: %{},
      denials: 0,
      files: MapSet.new(),
      added: 0,
      removed: 0,
      korium: %{
        searches: 0,
        search_hits: 0,
        saves: 0,
        save_errors: 0,
        code_searches: 0,
        code_hits: 0,
        index: 0,
        other: 0
      },
      save_failures: %{},
      prs: %{}
    }
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

  @doc "Adds the lines of a chunk of text to a tally (used by the tests)."
  def read_lines(tally \\ empty(), text) do
    text |> String.split("\n") |> Enum.reduce(tally, &line/2)
  end

  defp line("", t), do: t

  defp line(text, t) do
    case Jason.decode(text) do
      {:ok, %{} = e} -> entry(e, t)
      _ -> t
    end
  end

  defp entry(e, t) do
    t = context(e, t)

    case e do
      %{"type" => "assistant"} -> reply(e, t)
      %{"type" => "user"} -> user(e, t)
      %{"type" => "system", "subtype" => sub} -> system(sub, e, t)
      %{"type" => "custom-title", "customTitle" => v} -> title(t, :custom, v)
      %{"type" => "agent-name", "agentName" => v} -> title(t, :agent, v)
      %{"type" => "ai-title", "aiTitle" => v} -> title(t, :ai, v)
      %{"type" => "last-prompt", "lastPrompt" => v} -> %{t | last_prompt: clip(v)}
      %{"type" => "cost-state"} -> %{t | cost_state: e}
      %{"type" => "pr-link", "prUrl" => url} -> pr(e, url, t)
      _ -> t
    end
  end

  defp context(e, t) do
    at = time(e["timestamp"])

    %{
      t
      | first_at: t.first_at || at,
        last_at: at || t.last_at,
        cwd: e["cwd"] || t.cwd,
        git_branch: e["gitBranch"] || t.git_branch,
        branches: branch_seen(t.branches, e["gitBranch"], at),
        version: e["version"] || t.version,
        entrypoint: t.entrypoint || e["entrypoint"]
    }
  end

  # Each branch with when the session was first and last seen on it, in Unix
  # seconds: a session's runs on a branch are the ones it began while there.
  defp branch_seen(seen, branch, %DateTime{} = at) when is_binary(branch) and branch != "" do
    unix = DateTime.to_unix(at)

    case Enum.find_index(seen, &(&1.branch == branch)) do
      nil ->
        seen ++ [%{branch: branch, from: unix, to: unix}]

      i ->
        List.update_at(seen, i, &%{&1 | from: min(&1.from, unix), to: max(&1.to, unix)})
    end
  end

  defp branch_seen(seen, _, _), do: seen

  defp title(t, kind, v) when is_binary(v), do: %{t | titles: Map.put(t.titles, kind, clip(v))}
  defp title(t, _, _), do: t

  defp pr(e, url, t) do
    pr = %{number: e["prNumber"], repo: e["prRepository"], url: url, at: e["timestamp"]}
    %{t | prs: Map.put(t.prs, url, pr)}
  end

  # A model reply: its tokens (once per request id) and its tool calls.
  defp reply(e, t) do
    msg = e["message"] || %{}
    t = if e["isAbortedMidStream"], do: %{t | aborted: t.aborted + 1}, else: t

    t =
      case msg["usage"] do
        %{} = u ->
          id = e["requestId"] || msg["id"] || e["uuid"]
          writes = u["cache_creation"] || %{}
          cw_total = int(u["cache_creation_input_tokens"])
          cw_1h = int(writes["ephemeral_1h_input_tokens"])
          cw_5m = if writes == %{}, do: cw_total, else: int(writes["ephemeral_5m_input_tokens"])

          req = %{
            request_id: id,
            at: time(e["timestamp"]),
            model: msg["model"],
            effort: e["effort"],
            input: int(u["input_tokens"]),
            cache_read: int(u["cache_read_input_tokens"]),
            cache_write_5m: cw_5m,
            cache_write_1h: cw_1h,
            output: int(u["output_tokens"])
          }

          context = req.input + req.cache_read + cw_total

          %{
            t
            | requests: Map.put(t.requests, id, req),
              last_request: id,
              model: msg["model"] || t.model,
              effort: e["effort"] || t.effort,
              peak_context: max(t.peak_context, context)
          }

        _ ->
          t
      end

    msg
    |> blocks()
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.reduce(t, &tool_call/2)
  end

  defp tool_call(%{"name" => name, "id" => id} = b, t) do
    input = b["input"] || %{}
    tools = Map.update(t.tools, name, %{calls: 1, errors: 0}, &%{&1 | calls: &1.calls + 1})
    t = %{t | tools: tools, pending: Map.put(t.pending, id, name)}

    t =
      case input do
        %{"file_path" => f} when name in ["Edit", "Write", "MultiEdit", "NotebookEdit"] ->
          %{t | files: MapSet.put(t.files, f)}

        _ ->
          t
      end

    # Indexing is also done from the shell with the korium-cli.
    case {name, input} do
      {"Bash", %{"command" => cmd}} when is_binary(cmd) ->
        if cmd =~ ~r/korium-cli\s+index/, do: korium(t, :index, 1), else: t

      _ ->
        t
    end
  end

  defp tool_call(_, t), do: t

  # A user line is either a prompt or the results of tool calls.
  defp user(e, t) do
    msg = e["message"] || %{}
    t = if e["toolDenialKind"], do: %{t | denials: t.denials + 1}, else: t
    t = patch(e, t)
    results = msg |> blocks() |> Enum.filter(&(&1["type"] == "tool_result"))

    cond do
      results != [] ->
        Enum.reduce(results, t, &tool_result/2)

      e["isMeta"] || e["isCompactSummary"] || e["isSidechain"] ->
        t

      text = prompt_text(msg["content"]) ->
        %{t | prompts: t.prompts + 1, first_prompt: t.first_prompt || clip(text)}

      true ->
        t
    end
  end

  defp patch(%{"toolUseResult" => %{} = r}, t) do
    {a, r} = Usage.patch_lines(r)
    %{t | added: t.added + a, removed: t.removed + r}
  end

  defp patch(_, t), do: t

  defp tool_result(%{"tool_use_id" => id} = b, t) do
    name = t.pending[id]
    error? = b["is_error"] == true

    t =
      if name && error?,
        do: %{t | tools: Map.update!(t.tools, name, &%{&1 | errors: &1.errors + 1})},
        else: t

    t = %{t | pending: Map.delete(t.pending, id)}

    case name && korium_tool(name) do
      nil -> t
      tool -> korium_result(t, tool, error?, result_json(b["content"]), result_text(b["content"]))
    end
  end

  defp tool_result(_, t), do: t

  @doc "The Korium tool a tool name calls (\"agent_search\"), or nil."
  def korium_tool("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [server, tool] -> if server =~ "korium", do: tool, else: nil
      _ -> nil
    end
  end

  def korium_tool(_), do: nil

  @doc "Counts one Korium call by its tool name (\"agent_search\"); the Codex reader uses it too."
  def korium_call(t, tool, error?, json, text), do: korium_result(t, tool, error?, json, text)

  defp korium_result(t, "agent_search", error?, json, _text) do
    hit = not error? and match?(%{"result_count" => n} when is_integer(n) and n > 0, json)
    t |> korium(:searches, 1) |> korium(:search_hits, if(hit, do: 1, else: 0))
  end

  defp korium_result(t, "code_locate", error?, json, _text) do
    hit = not error? and match?(%{"results" => [_ | _]}, json)
    t |> korium(:code_searches, 1) |> korium(:code_hits, if(hit, do: 1, else: 0))
  end

  defp korium_result(t, "agent_capture", error?, json, text) do
    failed = error? or match?(%{"error" => _}, json)
    t = t |> korium(:saves, 1) |> korium(:save_errors, if(failed, do: 1, else: 0))

    if failed do
      kind = save_failure(text)
      %{t | save_failures: Map.update(t.save_failures, kind, 1, &(&1 + 1))}
    else
      t
    end
  end

  defp korium_result(t, "code_submit", _error?, _json, _text), do: korium(t, :index, 1)
  defp korium_result(t, _tool, _error?, _json, _text), do: korium(t, :other, 1)

  @doc """
  Why a Korium save failed: "blocked" (a safety hook stopped it), "invalid"
  (the call was missing a field or had the wrong shape) or "refused" (Korium
  turned it down, such as a capture filed under the wrong agent).
  """
  def save_failure(text) do
    cond do
      text =~ ~r/hook error|^Blocked:/ -> "blocked"
      text =~ ~r/InputValidationError|is required/ -> "invalid"
      true -> "refused"
    end
  end

  defp korium(t, key, n), do: %{t | korium: Map.update!(t.korium, key, &(&1 + n))}

  defp result_text(content) do
    case content do
      s when is_binary(s) -> s
      list when is_list(list) -> Enum.map_join(list, "", &((is_map(&1) && &1["text"]) || ""))
      _ -> ""
    end
  end

  defp result_json(content) do
    case Jason.decode(result_text(content)) do
      {:ok, %{} = m} -> m
      _ -> nil
    end
  end

  defp system("api_error", e, t),
    do: %{
      t
      | api_errors: t.api_errors + 1,
        retries: t.retries + if(e["retryAttempt"], do: 1, else: 0)
    }

  defp system("compact_boundary", _e, t), do: %{t | compactions: t.compactions + 1}

  defp system("turn_duration", e, t),
    do: %{t | turns: t.turns + 1, turn_ms: t.turn_ms + int(e["durationMs"])}

  defp system(_, _e, t), do: t

  defp prompt_text(s) when is_binary(s), do: real_prompt(s)

  defp prompt_text(list) when is_list(list) do
    list
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
    |> real_prompt()
  end

  defp prompt_text(_), do: nil

  # Messages the app writes on the person's behalf start with a tag.
  defp real_prompt(s) do
    s = String.trim(s)
    if s == "" or String.starts_with?(s, "<"), do: nil, else: s
  end

  defp blocks(%{"content" => list}) when is_list(list), do: Enum.filter(list, &is_map/1)
  defp blocks(_), do: []

  # ---------------------------------------------------------------------------
  # Turning tallies into a saved session

  @doc """
  The session record and its request rows, from the main file's tally and
  its subagents' ({tally, meta} each).
  """
  def to_record(main, subs, ctx) do
    %{prices: prices, machine: machine, session_id: sid} = ctx
    all = [main | Enum.map(subs, &elem(&1, 0))]
    price = Usage.price_for(main.model, prices)

    requests =
      for {tally, sub?} <- [{main, false} | Enum.map(subs, &{elem(&1, 0), true})],
          r <- Map.values(tally.requests) do
        %{
          machine: machine,
          session_id: sid,
          request_id: r.request_id,
          at: r.at,
          model: r.model,
          effort: r.effort,
          input_tokens: r.input,
          output_tokens: r.output,
          cache_read_tokens: r.cache_read,
          cache_write_tokens: r.cache_write_5m + r.cache_write_1h,
          cost: Usage.cost(r, prices),
          subagent: sub?
        }
      end

    sum = fn key -> Enum.sum(Enum.map(requests, &Map.fetch!(&1, key))) end
    tools = Enum.reduce(all, %{}, &merge_counts(&2, &1.tools))
    korium = Enum.reduce(all, %{}, &merge_counts(&2, &1.korium))
    cs = main.cost_state || %{}

    subagents =
      Enum.map(subs, fn {tally, meta} ->
        reqs = Map.values(tally.requests)

        %{
          type: meta[:type],
          description: meta[:description],
          model: tally.model,
          requests: length(reqs),
          cost: reqs |> Enum.map(&Usage.cost(&1, prices)) |> Enum.sum(),
          started_at: tally.first_at && DateTime.to_iso8601(tally.first_at),
          seconds:
            tally.first_at && tally.last_at && DateTime.diff(tally.last_at, tally.first_at),
          tool_calls: tally.tools |> Map.values() |> Enum.map(& &1.calls) |> Enum.sum()
        }
      end)

    models =
      requests
      |> Enum.group_by(& &1.model)
      |> Map.new(fn {m, rs} ->
        {m || "unknown", %{requests: length(rs), cost: rs |> Enum.map(& &1.cost) |> Enum.sum()}}
      end)

    files = Enum.reduce(all, MapSet.new(), &MapSet.union(&2, &1.files))

    session = %{
      machine: machine,
      session_id: sid,
      tool: ctx[:tool] || "claude",
      account: ctx.account,
      transcript: ctx.path,
      title: main.titles[:custom] || main.titles[:agent] || main.titles[:ai] || main.first_prompt,
      cwd: main.cwd,
      git_branch: main.git_branch,
      entrypoint: main.entrypoint,
      version: main.version,
      first_prompt: main.first_prompt,
      last_prompt: main.last_prompt,
      started_at: earliest(all),
      ended_at: latest(all),
      model: main.model,
      effort: main.effort,
      requests: length(requests),
      input_tokens: sum.(:input_tokens),
      output_tokens: sum.(:output_tokens),
      cache_read_tokens: sum.(:cache_read_tokens),
      cache_write_tokens: sum.(:cache_write_tokens),
      cost: sum.(:cost),
      peak_context: main.peak_context,
      context_window: (price && price.context) || main[:context_window],
      prompts: main.prompts,
      turns: main.turns,
      turn_ms: main.turn_ms,
      api_ms: cs["totalAPIDuration"],
      tool_ms: cs["totalToolDuration"],
      compactions: main.compactions,
      api_errors: Enum.sum(Enum.map(all, & &1.api_errors)),
      retries: Enum.sum(Enum.map(all, & &1.retries)),
      aborted: Enum.sum(Enum.map(all, & &1.aborted)),
      tool_calls: tools |> Map.values() |> Enum.map(& &1.calls) |> Enum.sum(),
      tool_errors: tools |> Map.values() |> Enum.map(& &1.errors) |> Enum.sum(),
      denials: Enum.sum(Enum.map(all, & &1.denials)),
      lines_added: Enum.sum(Enum.map(all, & &1.added)),
      lines_removed: Enum.sum(Enum.map(all, & &1.removed)),
      files_touched: MapSet.size(files),
      subagents: length(subs),
      subagent_cost: subagents |> Enum.map(& &1.cost) |> Enum.sum(),
      korium_searches: korium[:searches] || 0,
      korium_search_hits: korium[:search_hits] || 0,
      korium_saves: korium[:saves] || 0,
      korium_save_errors: korium[:save_errors] || 0,
      code_searches: korium[:code_searches] || 0,
      code_search_hits: korium[:code_hits] || 0,
      korium_index: korium[:index] || 0,
      korium_other: korium[:other] || 0,
      detail: %{
        tools: tools,
        models: models,
        subagents: subagents,
        files: files |> MapSet.to_list() |> Enum.sort(),
        prs: Map.values(main.prs),
        branches: main.branches,
        korium_save_failures: Enum.reduce(all, %{}, &merge_counts(&2, &1.save_failures))
      },
      source_size: ctx.size,
      source_mtime: ctx.mtime,
      captured_at: ctx.now,
      deleted_at: nil,
      source: ctx[:source]
    }

    {session, requests}
  end

  defp merge_counts(acc, counts) do
    Map.merge(acc, counts, fn
      _k, %{} = a, %{} = b -> Map.merge(a, b, fn _, x, y -> x + y end)
      _k, a, b -> a + b
    end)
  end

  defp earliest(tallies),
    do:
      tallies
      |> Enum.map(& &1.first_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> nil end)

  defp latest(tallies),
    do:
      tallies
      |> Enum.map(& &1.last_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

  # ---------------------------------------------------------------------------

  defp clip(s) when is_binary(s) do
    s = String.trim(s)
    if String.length(s) > 300, do: String.slice(s, 0, 299) <> "…", else: s
  end

  defp clip(_), do: nil

  defp time(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp time(_), do: nil

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0
end
