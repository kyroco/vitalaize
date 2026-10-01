defmodule Wallboard.Link.Session do
  @moduledoc """
  One session on another machine, as the hub knows it from the events its
  collector streamed (see `Wallboard.Collector.Filter` for what an event
  holds). Nothing here touches a file or the database.

  `apply/2` takes one event. From what has been taken, `card/4` gives the
  live card the board shows and `record/3` the rows the archive keeps, the
  same rows `Wallboard.Archive.Transcript.to_record/3` builds from a whole
  transcript.

  ## Any order, any number of times

  Events can arrive twice, and after a dropout an older one can arrive
  after a newer one. Every part of an event says how far into its file it
  was read (`position`), and the totals it carries are for the file up to
  there, so the part from the furthest position wins and the rest change
  nothing. A status carries its time, and the latest wins. So the same
  events give the same session whatever order they come in, with one
  exception: a status said again unchanged keeps the time it first began,
  which depends on the status before it having arrived. The link sends a
  session's statuses in the order they were made.

  ## What differs from a transcript

  A collector sends counts, never file names, so a saved session has no
  list of files, a file changed by the session and by a helper counts
  twice, and a helper agent has no type or description. Texts are the
  filter's (cut to 500 characters, invisible characters removed). A
  session's first and last times are those of its first and last line that
  told something new.
  """

  alias Wallboard.Archive.CodexTranscript
  alias Wallboard.Collector.Proto
  alias Wallboard.Sources.Usage

  @waiting_words %{
    PERMISSION: "A permission prompt is waiting for your approval",
    QUESTION: "It asked you a question",
    DIALOG: "A dialog is open and waiting for you",
    NETWORK: "A command is asking for network access",
    HELPER: "A helper is asking for your approval",
    GOAL: "It proposed a goal for you to approve"
  }

  @doc "A session nothing is known about yet."
  def new(machine, session_id) do
    %{
      machine: machine,
      session_id: session_id,
      tool: nil,
      account: nil,
      # file name => what its lines told, see `file/0`
      files: %{},
      # {position, %Proto.Summary{}} from the session's own file
      summary: nil,
      # The latest status: %{state, why, tool, since, question, at}
      status: nil,
      ended_at: nil
    }
  end

  defp file do
    %{
      subagent: false,
      position: 0,
      first_at: nil,
      last_at: nil,
      # request id => {position, at, %Proto.Request{}}
      requests: %{},
      # tool name => {position, calls, errors}
      tools: %{},
      # {position, message} each
      changes: nil,
      counts: nil
    }
  end

  @doc "Takes one event in."
  def apply(session, %Proto.Event{file: ""} = event) do
    Enum.reduce(event.items, session, fn %Proto.Item{body: body}, s ->
      case body do
        {:status, %Proto.Status{} = status} ->
          if s.status == nil or event.at >= s.status.at do
            new = %{
              state: status.state,
              why: status.why,
              tool: status.tool,
              since: status.since,
              question: status.question,
              at: event.at
            }

            # A collector says a status again after every reconnect. The
            # same status said again began when it first began. Only for a
            # session that is live: after an end, the same words are a new
            # status.
            same? =
              live?(s) and
                Map.drop(s.status, [:since, :at]) == Map.drop(new, [:since, :at])

            new = if same?, do: %{new | since: first(s.status.since, new.since)}, else: new
            %{s | status: new}
          else
            s
          end

        {:ended, _} ->
          %{s | ended_at: max(s.ended_at || 0, event.at)}

        _ ->
          s
      end
    end)
  end

  def apply(session, %Proto.Event{} = event) do
    pos = event.position
    f = Map.get(session.files, event.file) || file()

    f = %{
      f
      | subagent: f.subagent or event.subagent,
        position: max(f.position, pos),
        first_at: earlier(f.first_at, event.at),
        last_at: max(f.last_at || 0, event.at)
    }

    {f, session} =
      Enum.reduce(event.items, {f, session}, fn %Proto.Item{body: body}, {f, s} ->
        item(body, pos, event, f, s)
      end)

    %{session | files: Map.put(session.files, event.file, f)}
  end

  defp item({:started, %Proto.SessionStarted{} = started}, _pos, %{subagent: false}, f, s) do
    tool = if started.tool == :CODEX, do: "codex", else: "claude"
    {f, %{s | tool: tool, account: blank(started.account)}}
  end

  defp item({:request, %Proto.Request{} = r}, pos, event, f, s) do
    f =
      case f.requests[r.request_id] do
        {had, _, _} when had > pos -> f
        _ -> %{f | requests: Map.put(f.requests, r.request_id, {pos, event.at, r})}
      end

    {f, s}
  end

  defp item({:tool, %Proto.ToolTally{} = t}, pos, _event, f, s) do
    f =
      case f.tools[t.name] do
        {had, _, _} when had > pos -> f
        _ -> %{f | tools: Map.put(f.tools, t.name, {pos, t.calls, t.errors})}
      end

    {f, s}
  end

  defp item({:changes, %Proto.Changes{} = c}, pos, _event, f, s),
    do: {%{f | changes: newer(f.changes, pos, c)}, s}

  defp item({:counts, %Proto.Counts{} = c}, pos, _event, f, s),
    do: {%{f | counts: newer(f.counts, pos, c)}, s}

  defp item({:summary, %Proto.Summary{} = sum}, pos, %{subagent: false}, f, s),
    do: {f, %{s | summary: newer(s.summary, pos, sum)}}

  defp item(_body, _pos, _event, f, s), do: {f, s}

  defp newer({had, _} = old, pos, _new) when had > pos, do: old
  defp newer(_old, pos, new), do: {pos, new}

  # The earlier of two starts, where 0 means not known.
  defp first(0, b), do: b
  defp first(a, 0), do: a
  defp first(a, b), do: min(a, b)

  defp earlier(a, 0), do: a
  defp earlier(nil, b), do: b
  defp earlier(a, b), do: min(a, b)

  # ---------------------------------------------------------------------------
  # Reading it

  @doc """
  True while the session runs on its machine: it has said how it is doing,
  and has not ended since.
  """
  def live?(%{status: nil}), do: false
  def live?(%{status: status, ended_at: ended}), do: ended == nil or status.at > ended

  @doc "True when the session is live and waits on its person."
  def waiting?(s), do: live?(s) and s.status.state == :WAITING

  @doc "When the latest status began, in seconds since 1970."
  def since(%{status: %{since: since, at: at}}), do: if(since > 0, do: since, else: at)

  @doc "The status as the board and the archive word it: needs, working or idle."
  def state(%{status: %{state: :WAITING}}), do: :needs
  def state(%{status: %{state: :WORKING}}), do: :working
  def state(_), do: :idle

  @doc "The time of the last thing heard about the session, or nil."
  def last_at(s) do
    times =
      [s.status && s.status.at, s.ended_at | Enum.map(Map.values(s.files), & &1.last_at)]
      |> Enum.reject(&(&1 in [nil, 0]))

    if times == [], do: nil, else: Enum.max(times)
  end

  @doc "The name the board shows for the session."
  def name(s) do
    sum = summary(s)

    short(sum.title) || short(sum.first_prompt) || folder(sum.folder) || short_id(s)
  end

  # A Codex id starts with the time, so its end tells sessions apart.
  defp short_id(%{tool: "codex", session_id: id}), do: CodexTranscript.short_id(id)
  defp short_id(%{session_id: id}), do: String.slice(id, 0, 8)

  @doc """
  The session's card for the board's Live tab, shaped like the cards of
  the hub's own sessions (`Wallboard.Sources.Claude.build_session/4`), or
  nil when it is not live. `connected?` says whether its machine's stream
  is open; when it is not, the card is marked stale and keeps the status
  it had.
  """
  def card(s, connected?, prices, down_since \\ nil) do
    if live?(s) do
      sum = summary(s)
      status = state(s)
      since = unix(since(s))
      {mains, subs} = split(s)
      main = List.first(mains)
      requests = Enum.flat_map(mains ++ subs, &requests/1)
      last = main && last_request(main)
      model = blank(sum.model) || (last && blank(last.model))
      price = Usage.price_for(model, prices)
      window = (price && price[:context]) || (main && count(main, :context_window))
      context = last && context(last)
      where = if s.account in [nil, "main"], do: s.machine, else: "#{s.machine} · #{s.account}"

      %{
        key: Enum.join(["stream", s.machine, s.session_id], ":"),
        session_id: s.session_id,
        name: name(s),
        short_id: short_id(s),
        account: where,
        machine: s.machine,
        kind: "remote",
        folder: folder(sum.folder),
        repo: sum.repo |> blank() |> repo_name(),
        status: status,
        task: short(sum.last_prompt) || blank(sum.folder),
        why: if(status == :needs, do: why(s.status)),
        waiting_since: if(status == :needs, do: since),
        since: since,
        updated_at: unix(last_at(s)),
        started_at: unix(started_at(s)),
        tool: if(s.tool == "codex", do: :codex, else: :claude),
        stale: not connected?,
        stale_since: if(not connected?, do: unix(down_since || last_at(s))),
        detail: %{
          cost: requests |> Enum.map(& &1.cost) |> Enum.sum(),
          tokens:
            requests
            |> Enum.map(&(&1.input_tokens + &1.cache_read_tokens + &1.output_tokens))
            |> Enum.sum(),
          plan_used: nil,
          model_label: (price && price[:label]) || model,
          effort: blank(sum.effort) || (last && blank(last.effort)),
          context_pct:
            if(context && is_integer(window) && window > 0, do: round(context * 100 / window)),
          added: sum_changes(mains ++ subs, :lines_added),
          removed: sum_changes(mains ++ subs, :lines_removed),
          subagents: Enum.map(subs, fn _ -> %{name: "subagent", running: false} end)
        }
      }
    end
  end

  @doc """
  The session's row for the archive and its request rows, like
  `Wallboard.Archive.Transcript.to_record/3`, or nil for a session where
  nothing happened yet. `prices` are the hub's, used only for the size of
  the model's context; a request's cost is the one its collector worked
  out.
  """
  def record(s, prices, now) do
    {mains, subs} = split(s)
    main = List.first(mains)

    if main == nil or (requests(main) == [] and count(main, :prompts) == 0) do
      nil
    else
      sum = summary(s)
      all = mains ++ subs

      rows =
        for f <- all, {_, at, r} <- Map.values(f.requests) do
          %{
            machine: s.machine,
            session_id: s.session_id,
            request_id: r.request_id,
            at: if(at > 0, do: at),
            model: blank(r.model),
            effort: blank(r.effort),
            input_tokens: r.input_tokens,
            output_tokens: r.output_tokens,
            cache_read_tokens: r.cache_read_tokens,
            cache_write_tokens: r.cache_write_5m_tokens + r.cache_write_1h_tokens,
            cost: r.cost,
            subagent: f.subagent
          }
        end

      total = fn key -> rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() end
      over = fn key -> all |> Enum.map(&count(&1, key)) |> Enum.sum() end
      tools = tools(all)
      model = blank(sum.model)
      price = Usage.price_for(model, prices)
      korium = fn key -> all |> Enum.map(&korium(&1, key)) |> Enum.sum() end

      helpers =
        Enum.map(subs, fn f ->
          reqs = requests(f)

          %{
            type: nil,
            description: nil,
            model: reqs |> Enum.map(&blank(&1.model)) |> Enum.reject(&is_nil/1) |> List.last(),
            requests: length(reqs),
            cost: reqs |> Enum.map(& &1.cost) |> Enum.sum(),
            started_at:
              f.first_at && f.first_at |> DateTime.from_unix!() |> DateTime.to_iso8601(),
            seconds: f.first_at && f.last_at - f.first_at,
            tool_calls: f.tools |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.sum()
          }
        end)

      models =
        rows
        |> Enum.group_by(& &1.model)
        |> Map.new(fn {m, rs} ->
          {m || "unknown", %{requests: length(rs), cost: rs |> Enum.map(& &1.cost) |> Enum.sum()}}
        end)

      session = %{
        machine: s.machine,
        session_id: s.session_id,
        tool: s.tool || "claude",
        account: s.account,
        transcript: nil,
        title: blank(sum.title) || blank(sum.first_prompt),
        cwd: blank(sum.folder),
        git_branch: blank(sum.branch),
        entrypoint: blank(sum.entrypoint),
        version: blank(sum.version),
        first_prompt: blank(sum.first_prompt),
        last_prompt: blank(sum.last_prompt),
        started_at: started_at(s),
        ended_at: all |> Enum.map(& &1.last_at) |> Enum.reject(&(&1 in [nil, 0])) |> latest(),
        model: model,
        effort: blank(sum.effort),
        requests: length(rows),
        input_tokens: total.(:input_tokens),
        output_tokens: total.(:output_tokens),
        cache_read_tokens: total.(:cache_read_tokens),
        cache_write_tokens: total.(:cache_write_tokens),
        cost: total.(:cost),
        peak_context: count(main, :peak_context),
        context_window: (price && price[:context]) || positive(count(main, :context_window)),
        prompts: count(main, :prompts),
        turns: count(main, :turns),
        turn_ms: count(main, :turn_ms),
        api_ms: positive(count(main, :api_ms)),
        tool_ms: positive(count(main, :tool_ms)),
        compactions: count(main, :compactions),
        api_errors: over.(:api_errors),
        retries: over.(:retries),
        aborted: over.(:aborted),
        tool_calls: tools |> Map.values() |> Enum.map(& &1.calls) |> Enum.sum(),
        tool_errors: tools |> Map.values() |> Enum.map(& &1.errors) |> Enum.sum(),
        denials: over.(:denials),
        lines_added: sum_changes(all, :lines_added),
        lines_removed: sum_changes(all, :lines_removed),
        files_touched: sum_changes(all, :files_touched),
        subagents: length(subs),
        subagent_cost: helpers |> Enum.map(& &1.cost) |> Enum.sum(),
        korium_searches: korium.(:searches),
        korium_search_hits: korium.(:search_hits),
        korium_saves: korium.(:saves),
        korium_save_errors: korium.(:save_errors),
        code_searches: korium.(:code_searches),
        code_search_hits: korium.(:code_hits),
        korium_index: korium.(:index),
        korium_other: korium.(:other),
        detail: %{
          tools: tools,
          models: models,
          subagents: helpers,
          files: [],
          prs: for(pr <- sum.prs, do: %{number: pr.number, repo: pr.repo, url: pr.url, at: nil}),
          korium_save_failures: %{}
        },
        source_size: nil,
        source_mtime: nil,
        captured_at: now,
        deleted_at: nil,
        source: "stream"
      }

      {session, rows}
    end
  end

  # ---------------------------------------------------------------------------

  defp summary(%{summary: {_, %Proto.Summary{} = sum}}), do: sum
  defp summary(_), do: %Proto.Summary{}

  # The session's own files, then its helpers', each in the order of their
  # names so the same events always give the same rows.
  defp split(s) do
    {subs, mains} =
      s.files |> Enum.sort() |> Enum.map(&elem(&1, 1)) |> Enum.split_with(& &1.subagent)

    {mains, subs}
  end

  defp requests(f),
    do: f.requests |> Map.values() |> Enum.sort() |> Enum.map(fn {_, _, r} -> r end)

  # The reply from furthest into the file.
  defp last_request(f), do: f |> requests() |> List.last()

  # What the model had in front of it for a reply.
  defp context(r),
    do: r.input_tokens + r.cache_read_tokens + r.cache_write_5m_tokens + r.cache_write_1h_tokens

  defp count(%{counts: {_, counts}}, key), do: Map.fetch!(counts, key)
  defp count(_, _key), do: 0

  defp korium(%{counts: {_, %{korium: %Proto.Korium{} = k}}}, key), do: Map.fetch!(k, key)
  defp korium(_, _key), do: 0

  defp sum_changes(files, key) do
    files
    |> Enum.map(fn
      %{changes: {_, changes}} -> Map.fetch!(changes, key)
      _ -> 0
    end)
    |> Enum.sum()
  end

  defp tools(files) do
    Enum.reduce(files, %{}, fn f, acc ->
      Enum.reduce(f.tools, acc, fn {name, {_, calls, errors}}, acc ->
        Map.update(
          acc,
          name,
          %{calls: calls, errors: errors},
          &%{calls: &1.calls + calls, errors: &1.errors + errors}
        )
      end)
    end)
  end

  defp started_at(s) do
    s.files
    |> Map.values()
    |> Enum.map(& &1.first_at)
    |> Enum.reject(&(&1 in [nil, 0]))
    |> Enum.min(fn -> nil end)
  end

  defp latest([]), do: nil
  defp latest(times), do: Enum.max(times)

  # Why it waits, in the board's words. The question itself when the
  # collector sent one, and the tool's name for a permission request.
  defp why(%{why: :QUESTION, question: question}) when question != "", do: question

  defp why(%{why: :PERMISSION, tool: tool}) when tool != "",
    do: "Asks for your approval to use " <> tool

  defp why(%{why: why}), do: Map.get(@waiting_words, why, "Waiting on you")

  defp repo_name(nil), do: nil
  defp repo_name(repo), do: repo |> String.split("/") |> List.last()

  defp folder(""), do: nil
  defp folder(path), do: Path.basename(path)

  defp short(text) do
    line =
      text |> String.split("\n", trim: true) |> List.first() |> Kernel.||("") |> String.trim()

    cond do
      line == "" -> nil
      String.length(line) > 90 -> String.slice(line, 0, 90) <> "…"
      true -> line
    end
  end

  defp blank(""), do: nil
  defp blank(text), do: text

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  defp unix(nil), do: nil

  defp unix(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, at} -> at
      _ -> nil
    end
  end
end
