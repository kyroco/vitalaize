defmodule Wallboard.Collector.Filter do
  @moduledoc """
  Decides what leaves a collector's machine. It turns the lines of a Claude
  or Codex session file, and a session's live status, into the messages the
  collector streams to the hub. Nothing else builds those messages, so what
  this module lets through is all that crosses the network.

  ## The messages

  They are defined in `priv/protos/collector.proto` and built into the
  `Wallboard.Collector.Proto` modules. One two-way stream carries them.

  Collector to hub (`FromCollector`):

    * `Hello`: the machine's name, its OS, the collector's version and the
      folders it watches. First on every stream.
    * `Event`: one thing learned about a session. It holds one of:
        * `SessionStarted`: Claude or Codex, and the login's short name
        * `Request`: one model reply's tokens by kind, cost, model, effort
          and whether a helper agent made it; the event's `at` is its time
        * `ToolTally`: one tool's name, calls and errors
        * `Changes`: lines added, lines removed and how many files changed
        * `Status`: working, waiting or idle, with the kind of wait
        * `Summary`: the short texts listed under "What may leave"
        * `SessionEnded`
        * `Counts`: prompts, turns, time, errors, context size and Korium use
    * `Ack`: the collector got the hub message with that id.

  Hub to collector (`FromHub`, each with an id the collector acks):

    * `Resume`: the last position the hub has for each session file
    * `BackSoon`: the hub is restarting on purpose; keep data and retry
    * `Disconnected`: this machine was removed; stop
    * `Answer`: empty, kept for answers to waiting agents (VIT-11)

  ## Positions, and why a repeat is harmless

  Every event names its session, its file and the byte just past the line
  it came from. The hub keeps the highest position per session and file and
  sends it back in `Resume`, and the collector reads on from there.

  `ToolTally`, `Changes`, `Counts` and `Summary` hold the totals for their
  file so far, not what one line added, and a `Request` is whole. So the hub
  saves the newest one and a repeated event changes nothing. The same lines
  always give the same events at the same positions.

  To resume, a collector reads the file again from the start through
  `read/2`, since the totals need every line, and sends only the events
  past the hub's position.

  A session's helper agents write their own files. Those give `Request`,
  `ToolTally`, `Changes` and `Counts` events under the main session's id,
  with `subagent` set on each request, and never a `Summary`. The hub adds a
  session's files together; a file changed by both the session and a helper
  counts twice in files touched.

  ## What may leave

  Numbers, times, ids and these short names, each checked for shape and
  dropped when it is not a plain name: model, effort, tool names, the
  Claude Code or Codex version, what started the session, the login's short
  name.

  Free text, clipped, and nothing else:

    * the session title
    * the first and last prompt, clipped the way the readers clip them
      (300 characters for Claude, 500 for Codex). The last prompt is the
      latest one so far, so over a live session each prompt leaves once,
      clipped, while it is the latest
    * the folder and the git branch
    * pull request links (the link, its number and its repo)
    * the folder's GitHub repository as owner/name

  What never leaves: any other prompt, the model's replies and thinking,
  tool inputs and outputs, commands, file names and file contents, patches,
  pasted text and images, and the words of the question a session waits on
  (only its kind: a permission request, a question and so on).

  ## Changing the messages

  Edit `priv/protos/collector.proto`, then build the modules again and
  format them:

      mix escript.install hex protobuf 0.17.0
      protoc --elixir_out=lib -I priv/protos collector.proto
      mix format

  Add fields; never reuse or renumber one. A new text field needs a line in
  the list above and a case in `test/wallboard/collector_filter_test.exs`.
  """

  alias Wallboard.Archive.{CodexTranscript, Transcript}
  alias Wallboard.Collector.Proto
  alias Wallboard.GitRemote
  alias Wallboard.Sources.Usage

  @text_limit 500
  @name_limit 100

  @doc """
  The filter's state for one session file, before any of it is read.

  `ctx` holds `tool` (`:claude` or `:codex`), `session_id` and `file` (the
  file's path inside its watched folder). Optional: `subagent` (true for a
  helper agent's file), `account`, `prices` (as in settings, for the cost),
  `title` (Codex's own name for the thread) and `repo` (a function from a
  folder to its "owner/name", `Wallboard.GitRemote.github_repo/1` unless
  given).
  """
  def new(%{tool: tool, session_id: _, file: _} = ctx) when tool in [:claude, :codex] do
    reader = if tool == :codex, do: CodexTranscript, else: Transcript

    %{
      ctx: ctx,
      reader: reader,
      tally: reader.empty(),
      position: 0,
      rest: "",
      started: false,
      repo: {nil, ""},
      changes: %Proto.Changes{},
      counts: counts(reader.empty()),
      summary: %Proto.Summary{}
    }
  end

  @doc "How far into the file the state has read: the byte after its last whole line."
  def position(state), do: state.position

  @doc """
  Reads the next bytes of the file and returns `{events, state}`. A last
  line with no line break yet is kept until the rest of it arrives.
  """
  def read(state, chunk) when is_binary(chunk) do
    [rest | full] = :binary.split(state.rest <> chunk, "\n", [:global]) |> Enum.reverse()

    {events, state} =
      full
      |> Enum.reverse()
      |> Enum.reduce({[], state}, fn text, {events, s} ->
        s = %{s | position: s.position + byte_size(text) + 1}
        {new, s} = line(text, s)
        {[new | events], s}
      end)

    {events |> Enum.reverse() |> List.flatten(), %{state | rest: rest}}
  end

  @doc """
  The event for a session's live status. `state` is `:working`, `:needs`
  (or `:waiting`) or `:idle`. Options: `why`, the kind of wait
  (`:permission`, `:question`, `:dialog`, `:network`, `:helper`, `:goal`, or
  the word `claude agents` gives in `waitingFor`); `tool`, the name of the
  tool a permission request is for; `since`, when the state began; `at`.
  """
  def status(ctx, state, opts \\ []) when state in [:working, :needs, :waiting, :idle] do
    waiting? = state in [:needs, :waiting]

    body = %Proto.Status{
      state:
        case state do
          :working -> :WORKING
          :idle -> :IDLE
          _ -> :WAITING
        end,
      why: if(waiting?, do: why(opts[:why]), else: :WHY_UNKNOWN),
      tool: if(waiting?, do: name(opts[:tool]), else: ""),
      since: unix(opts[:since])
    }

    event(ctx, "", 0, unix(opts[:at]), {:status, body})
  end

  @doc "The event for a session that is over."
  def ended(ctx, at), do: event(ctx, "", 0, unix(at), {:ended, %Proto.SessionEnded{}})

  @doc "The first message on a stream, from `machine`, `os`, `version` and `folders`."
  def hello(info) do
    folders = if is_list(info[:folders]), do: info[:folders], else: []

    %Proto.Hello{
      machine: text(info[:machine], @name_limit),
      os: name(info[:os]),
      version: name(info[:version]),
      folders: folders |> Enum.map(&text/1) |> Enum.reject(&(&1 == ""))
    }
  end

  # ---------------------------------------------------------------------------
  # One line

  defp line(text, s) do
    old = s.tally
    new = add(s.reader, old, text)
    s = %{s | tally: new}
    main? = s.ctx[:subagent] != true

    {started, s} = started(new, s, main?)
    {changes, s} = replaced(s, :changes, changes(new))
    {counts, s} = replaced(s, :counts, counts(new))
    {summary, s} = if main?, do: summary(new, s), else: {[], s}

    bodies = started ++ request(old, new, s) ++ tools(old, new) ++ changes ++ counts ++ summary
    at = unix(new.last_at)
    {Enum.map(bodies, &event(s.ctx, s.ctx.file, s.position, at, &1)), s}
  end

  # A line the reader cannot take is skipped, so one bad line never stops a
  # session's stream.
  defp add(reader, tally, text) do
    reader.read_lines(tally, text)
  rescue
    _ -> tally
  end

  defp started(new, %{started: false} = s, true) when not is_nil(new.first_at) do
    body = %Proto.SessionStarted{
      tool: if(s.ctx.tool == :codex, do: :CODEX, else: :CLAUDE),
      account: name(s.ctx[:account])
    }

    {[{:started, body}], %{s | started: true}}
  end

  defp started(_new, s, _main?), do: {[], s}

  # The readers note which request a line added or changed.
  defp request(old, new, s) do
    id = new.last_request
    req = id && new.requests[id]

    if req && old.requests[id] != req do
      [
        {:request,
         %Proto.Request{
           request_id: name(id),
           model: name(req.model),
           effort: name(req.effort),
           input_tokens: count(req.input),
           output_tokens: count(req.output),
           cache_read_tokens: count(req.cache_read),
           cache_write_5m_tokens: count(req.cache_write_5m),
           cache_write_1h_tokens: count(req.cache_write_1h),
           cost: cost(req, s.ctx[:prices]),
           subagent: s.ctx[:subagent] == true
         }}
      ]
    else
      []
    end
  end

  defp cost(%{model: model} = req, %{} = prices) when is_binary(model),
    do: Usage.cost(req, prices) * 1.0

  defp cost(_req, _prices), do: 0.0

  defp tools(%{tools: same}, %{tools: same}), do: []

  defp tools(old, new) do
    for {tool, c} <- Enum.sort(new.tools), old.tools[tool] != c, name(tool) != "" do
      {:tool, %Proto.ToolTally{name: name(tool), calls: count(c.calls), errors: count(c.errors)}}
    end
  end

  defp changes(t) do
    %Proto.Changes{
      lines_added: count(t.added),
      lines_removed: count(t.removed),
      files_touched: MapSet.size(t.files)
    }
  end

  defp counts(t) do
    cost_state = if is_map(t.cost_state), do: t.cost_state, else: %{}
    k = t.korium

    %Proto.Counts{
      prompts: count(t.prompts),
      turns: count(t.turns),
      turn_ms: count(t.turn_ms),
      api_ms: count(cost_state["totalAPIDuration"]),
      tool_ms: count(cost_state["totalToolDuration"]),
      compactions: count(t.compactions),
      api_errors: count(t.api_errors),
      retries: count(t.retries),
      aborted: count(t.aborted),
      denials: count(t.denials),
      peak_context: count(t.peak_context),
      context_window: count(t[:context_window]),
      korium: %Proto.Korium{
        searches: count(k.searches),
        search_hits: count(k.search_hits),
        saves: count(k.saves),
        save_errors: count(k.save_errors),
        code_searches: count(k.code_searches),
        code_hits: count(k.code_hits),
        index: count(k.index),
        other: count(k.other)
      }
    }
  end

  defp summary(t, s) do
    {repo, s} = repo(t.cwd, s)

    replaced(s, :summary, %Proto.Summary{
      title: text(t.titles[:custom] || t.titles[:agent] || s.ctx[:title] || t.titles[:ai]),
      first_prompt: text(t.first_prompt),
      last_prompt: text(t.last_prompt),
      folder: text(t.cwd),
      branch: text(t.git_branch, 200),
      repo: repo,
      prs: prs(t.prs),
      model: name(t.model),
      effort: name(t.effort),
      version: name(t.version),
      entrypoint: name(t.entrypoint)
    })
  end

  # Asked again only when the folder changes: it reads the folder's git config.
  defp repo(cwd, %{repo: {cwd, repo}} = s), do: {repo, s}

  defp repo(cwd, s) do
    find = s.ctx[:repo] || (&GitRemote.github_repo/1)
    repo = if is_binary(cwd), do: repo_name(find.(cwd)), else: ""
    {repo, %{s | repo: {cwd, repo}}}
  end

  defp prs(prs) do
    for {_, pr} <- Enum.sort(prs),
        is_binary(pr.url),
        pr.url =~ ~r{\Ahttps://[\w.-]+/[\w.-]+/[\w.-]+/pull/\d+\z},
        byte_size(pr.url) <= 300 do
      %Proto.PullRequest{url: pr.url, number: count(pr.number), repo: repo_name(pr.repo)}
    end
  end

  # The event for a total that changed, or none when it is as last sent.
  defp replaced(s, key, body) do
    if Map.fetch!(s, key) == body, do: {[], s}, else: {[{key, body}], Map.put(s, key, body)}
  end

  defp event(ctx, file, position, at, body) do
    %Proto.Event{
      session_id: name(ctx.session_id),
      file: text(file),
      position: position,
      at: at,
      body: body
    }
  end

  # ---------------------------------------------------------------------------
  # The only ways a value gets into a message

  @waits %{
    :permission => :PERMISSION,
    "permission prompt" => :PERMISSION,
    :question => :QUESTION,
    "input needed" => :QUESTION,
    :dialog => :DIALOG,
    "dialog open" => :DIALOG,
    :network => :NETWORK,
    "sandbox request" => :NETWORK,
    :helper => :HELPER,
    "worker request" => :HELPER,
    :goal => :GOAL,
    "goal proposal" => :GOAL
  }

  defp why(nil), do: :WHY_UNKNOWN
  defp why(kind), do: Map.get(@waits, kind, :OTHER)

  # Allowed free text, clipped.
  defp text(s, limit \\ @text_limit)

  defp text(s, limit) when is_binary(s) do
    s = String.trim(s)

    cond do
      not String.valid?(s) -> ""
      String.length(s) > limit -> String.slice(s, 0, limit - 1) <> "…"
      true -> s
    end
  end

  defp text(_, _), do: ""

  # A plain name such as a model, a tool or a version. Anything else, a
  # sentence or a line of code say, is dropped whole.
  defp name(s) when is_binary(s) do
    if s =~ ~r"\A[\w.:@/+\[\]-]+( [\w.:@/+\[\]-]+){0,3}\z" and byte_size(s) <= @name_limit,
      do: s,
      else: ""
  end

  defp name(_), do: ""

  defp repo_name(s) when is_binary(s) do
    if s =~ ~r{\A[\w.-]+/[\w.-]+\z} and byte_size(s) <= 200, do: s, else: ""
  end

  defp repo_name(_), do: ""

  defp count(n) when is_integer(n) and n > 0, do: n
  defp count(n) when is_float(n) and n > 0, do: round(n)
  defp count(_), do: 0

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)
  defp unix(_), do: 0
end
