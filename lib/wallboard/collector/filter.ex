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
    * `Event`: what one line of a session file told the collector, as a
      list of items. An item is one of:
        * `SessionStarted`: Claude or Codex, and the login's short name
        * `Request`: one model reply's tokens by kind, cost, model, effort
          and whether a helper agent made it; the event's `at` is its time
        * `ToolTally`: one tool's name, calls and errors
        * `Changes`: lines added, lines removed and how many files changed
        * `Status`: working, waiting or idle, with the kind of wait and
          what the session asks
        * `Summary`: the short texts listed under "What may leave"
        * `SessionEnded`
        * `Counts`: prompts, turns, time, errors, context size and Korium use
    * `Ack`: the collector got the hub message with that id.
    * `RunnerStates`: the GitHub Actions runners running on the machine
      now, each by name and state (online or busy) only. Sent whole when
      it changes and once after each connect; the hub keeps the latest in
      memory and saves none of it (see `Wallboard.Collector.Runners`).

  Each hello and event carries a `seq` that counts up, so the hub can say
  how far it saved. `RunnerStates` has none and gets no answer: an older
  hub that does not know it skips it, and the link stays up.

  Hub to collector (`FromHub`, each with an id the collector acks):

    * `Resume`: the last position the hub has for each session file
    * `Stored`: the hub saved every collector message up to that `seq`
    * `BackSoon`: the hub is restarting on purpose; keep data and retry
    * `Disconnected`: this machine was removed; stop
    * `Answer`: empty, kept for answers to waiting agents (VIT-11)

  ## Positions, and why a repeat is harmless

  Every event names its session, its file and the byte just past the line
  it came from, and carries that line's time. Two exceptions, both in Codex
  files: the lines before a session's first turn carry no time (`at` is
  0), and the lines of a
  chat the Codex app copied in carry the time the conversation happened,
  not the moment of the copy (see `Wallboard.Archive.CodexTranscript`).
  All of a line's items travel in that one event, so a line
  reaches the hub whole or not at all. The hub keeps the highest position
  per session and file and sends it back in `Resume`, and the collector
  sends only the events past it.

  `ToolTally`, `Changes`, `Counts` and `Summary` hold the totals for their
  file so far, not what one line added, and a `Request` is whole. So the hub
  saves the newest one and a repeated event changes nothing. The same lines
  always give the same events at the same positions.

  To resume, a collector reads the file again from the start through
  `read/2`, since the totals need every line, and drops the events at or
  before the hub's position.

  A session's helper agents write their own files. Those give `Request`,
  `ToolTally`, `Changes` and `Counts` items under the main session's id, in
  events marked `subagent`, and never a `SessionStarted` or a `Summary`: a
  helper's prompts are written by a model, not the person. A Codex file
  that names a parent thread is a helper's whatever the caller says. A file
  changed by both the session and a helper counts twice in files touched.

  ## What may leave

  Numbers, times and ids, and these short names. Each has its own shape and
  is dropped when it does not fit, so a sentence, a path or a line of code
  never passes as a name:

    * model (`claude-opus-5-5`), effort (`high`), version (`2.1.284`)
    * what started the session (`cli`, `Codex Desktop`) and the login's
      short name
    * tool names: a plain word (`Bash`) or `mcp__server__tool`, and no more
      than 200 different ones per file. The calls of every tool whose name
      does not pass are added up under the one name `other`, so the hub's
      count of tool calls is whole
    * a request id of letters, digits, `_` and `-`; any other id leaves as
      a hash of itself
    * the name of a GitHub Actions runner on the machine (`kyroco-air-1`):
      letters, digits, `.`, `_` and `-`, up to 64. A runner whose name does
      not fit is not sent at all. Only its name and whether it is online
      or busy leave; never its folder, its jobs or its logs

  Free text, and nothing else. Each is cut to 500 characters, with
  characters that do not show (control, formatting and tag characters)
  taken out and line breaks turned into spaces:

    * the session title
    * the first and last prompt, clipped the way the readers clip them
      (300 characters for Claude, 500 for Codex), including what the
      person typed in a Codex file of the older shape. The last prompt is the
      latest one so far, so over a live session each prompt leaves once,
      clipped, while it is the latest
    * the folder and the git branch
    * pull request links on github.com, 50 at most; the number and the
      repo are read from the link
    * the folder's GitHub repository as owner/name
    * what a session asks its person while it waits on an answer, so a
      card on another machine can quote it. Only in a status that says
      waiting on a question; the words of a permission request, which name
      the command or the file, never leave.

  What never leaves: any other prompt, the model's other replies and its
  thinking, tool inputs and outputs, commands, file names and file
  contents, patches, and pasted text and images.

  A name-shaped value is still text someone chose: a model told to call a
  tool named after a short secret would get that name out. The shapes and
  the limit on tool names keep that to a few short words.

  ## Changing the messages

  Edit `priv/protos/collector.proto`, then build the modules again and
  format them:

      mix escript.install hex protobuf 0.17.0
      protoc --elixir_out=plugins=grpc:lib -I priv/protos collector.proto
      mix format

  `plugins=grpc` also builds the service and the stub the link uses
  (`Wallboard.Link`).

  Add fields; never reuse or renumber one. A new text field needs a line in
  the list above and a case in `test/wallboard/collector_filter_test.exs`.
  """

  alias Wallboard.Archive.{CodexTranscript, Transcript}
  alias Wallboard.Collector.Proto
  alias Wallboard.GitRemote
  alias Wallboard.Sources.Usage

  @text_limit 500
  # The name the calls of tools with no sendable name are counted under.
  @other "other"
  @tool_limit 200
  @pr_limit 50
  @runner_limit 100
  # The largest number a message field can hold.
  @max 0xFFFFFFFFFFFFFFFF

  # The parts of a reader's tally each kind of item is built from. An item
  # is built again only when one of them changed.
  @changes_keys [:added, :removed, :files]
  @counts_keys [
    :prompts,
    :turns,
    :turn_ms,
    :cost_state,
    :compactions,
    :api_errors,
    :retries,
    :aborted,
    :denials,
    :peak_context,
    :context_window,
    :korium
  ]
  @summary_keys [
    :titles,
    :first_prompt,
    :last_prompt,
    :cwd,
    :git_branch,
    :prs,
    :model,
    :effort,
    :version,
    :entrypoint
  ]

  @doc """
  The filter's state for one session file, before any of it is read.

  `ctx` holds `tool` (`:claude` or `:codex`), `session_id` and `file` (the
  file's path inside its watched folder). Optional: `subagent` (true for a
  helper agent's file), `account`, `prices` (as in settings, for the cost),
  `title` (Codex's own name for the thread) and `repo` (a function from a
  folder to its "owner/name", `Wallboard.GitRemote.github_repo/1` unless
  given).

  The session id and the file are the hub's key for resuming, so they are
  sent as given. One that could not be sent as given raises here.
  """
  def new(%{tool: tool, session_id: _, file: file} = ctx) when tool in [:claude, :codex] do
    check_key!(ctx)
    if file == "", do: raise(ArgumentError, "a session file needs a name")
    reader = if tool == :codex, do: CodexTranscript, else: Transcript

    %{
      ctx: ctx,
      reader: reader,
      tally: reader.empty(),
      position: 0,
      rest: "",
      started: false,
      helper: ctx[:subagent] == true,
      repo: {nil, ""},
      tools: MapSet.new(),
      other: {0, 0},
      changes: %Proto.Changes{},
      counts: counts(reader.empty()),
      summary: %Proto.Summary{}
    }
  end

  @doc "How far into the file the state has read: the byte after its last whole line."
  def position(state), do: state.position

  @doc """
  The reader's tally of the file so far. It holds the session's text, so it
  is for the collector's own use on its machine (working out a Codex
  session's live status) and is never sent.
  """
  def tally(state), do: state.tally

  @doc """
  Reads the next bytes of the file and returns `{events, state}`: one event
  for each line that told something new. A last line with no line break yet
  is kept until the rest of it arrives.
  """
  def read(state, chunk) when is_binary(chunk) do
    [rest | full] = :binary.split(state.rest <> chunk, "\n", [:global]) |> Enum.reverse()

    {events, state} =
      full
      |> Enum.reverse()
      |> Enum.reduce({[], state}, fn text, {events, s} ->
        s = %{s | position: s.position + byte_size(text) + 1}
        {new, s} = line(text, s)
        {new ++ events, s}
      end)

    {Enum.reverse(events), %{state | rest: rest}}
  end

  @doc """
  The event for a session's live status. `state` is `:working`, `:needs`
  (or `:waiting`) or `:idle`. Options: `why`, the kind of wait
  (`:permission`, `:question`, `:dialog`, `:network`, `:helper`, `:goal`, or
  the word `claude agents` gives in `waitingFor`); `tool`, the name of the
  tool a permission request is for; `question`, what the session asks its
  person, kept only when `why` is a question; `since`, when the state
  began; `at`.
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
      tool: if(waiting?, do: tool_name(opts[:tool]), else: ""),
      since: unix(opts[:since]),
      # Only a question the session put to its person. What a permission
      # request says holds the command or the file it is about.
      question: if(waiting? and why(opts[:why]) == :QUESTION, do: text(opts[:question]), else: "")
    }

    event(ctx, "", 0, unix(opts[:at]), false, status: body)
  end

  @doc "The event for a session that is over."
  def ended(ctx, at), do: event(ctx, "", 0, unix(at), false, ended: %Proto.SessionEnded{})

  @doc "The first message on a stream, from `machine`, `os`, `version` and `folders`."
  def hello(info) do
    folders = if is_list(info[:folders]), do: info[:folders], else: []

    %Proto.Hello{
      machine: text(info[:machine], 100),
      os: text(info[:os], 100),
      version: text(info[:version], 100),
      folders: folders |> Enum.map(&text/1) |> Enum.reject(&(&1 == "")) |> Enum.take(20)
    }
  end

  @doc """
  The runners running on this machine now (`[%{name, state}]`, `state`
  `:online` or `:busy`; see `Wallboard.Collector.Runners`), as the message
  for the hub. A runner whose name does not have a runner name's shape is
  left out, and at most #{@runner_limit} are sent.
  """
  def runners(list) when is_list(list) do
    runners =
      for %{name: name, state: state} <- list,
          name = runner_name(name),
          name != "",
          state in [:online, :busy] do
        %Proto.RunnerState{name: name, state: if(state == :busy, do: :BUSY, else: :ONLINE)}
      end

    %Proto.RunnerStates{runners: runners |> Enum.uniq_by(& &1.name) |> Enum.take(@runner_limit)}
  end

  # ---------------------------------------------------------------------------
  # One line

  # A line that cannot be read or turned into items is skipped, so one bad
  # line never stops a session's stream.
  defp line(text, s) do
    old = s.tally
    new = s.reader.read_lines(old, text)
    # Once a file has named a parent thread it stays a helper's, even if a
    # later line of it says otherwise.
    helper? = s.helper or new[:parent_id] != nil
    s = %{s | tally: new, helper: helper?}

    {started, s} = started(s, helper?)
    {tools, s} = tools(old, new, s)
    {changes, s} = changed(old, new, s, :changes, @changes_keys, &changes/1)
    {counts, s} = changed(old, new, s, :counts, @counts_keys, &counts/1)

    {summary, s} =
      if helper?, do: {[], s}, else: changed(old, new, s, :summary, @summary_keys, &summary/2)

    items = started ++ request(old, new, s, helper?) ++ tools ++ changes ++ counts ++ summary

    if items == [] do
      {[], s}
    else
      {[event(s.ctx, s.ctx.file, s.position, unix(new.last_at), helper?, items)], s}
    end
  rescue
    _ -> {[], s}
  catch
    _, _ -> {[], s}
  end

  # First in a session's own file, whatever its first line holds, so the
  # hub knows the session before anything else about it.
  defp started(%{started: false} = s, false) do
    body = %Proto.SessionStarted{
      tool: if(s.ctx.tool == :codex, do: :CODEX, else: :CLAUDE),
      account: account(s.ctx[:account])
    }

    {[started: body], %{s | started: true}}
  end

  defp started(s, _helper?), do: {[], s}

  # The readers note which request a line added or changed. A reply written
  # as several lines changes only its time; that is not sent again.
  # Replies with no id at all share one place in the reader, so each one
  # that differs, if only by its time, is a request of its own.
  defp request(old, new, s, helper?) do
    id = new.last_request

    with {:ok, req} <- Map.fetch(new.requests, id),
         before = old.requests[id] || %{},
         true <-
           if(is_nil(id),
             do: req != before,
             else: Map.delete(req, :at) != Map.delete(before, :at)
           ) do
      req = %{
        req
        | input: count(req.input),
          output: count(req.output),
          cache_read: count(req.cache_read),
          cache_write_5m: count(req.cache_write_5m),
          cache_write_1h: count(req.cache_write_1h)
      }

      [
        request: %Proto.Request{
          request_id: request_id(id, s.position),
          model: model(req.model),
          effort: effort(req.effort),
          input_tokens: req.input,
          output_tokens: req.output,
          cache_read_tokens: req.cache_read,
          cache_write_5m_tokens: req.cache_write_5m,
          cache_write_1h_tokens: req.cache_write_1h,
          cost: cost(req, s.ctx[:prices]),
          subagent: helper?
        }
      ]
    else
      _ -> []
    end
  end

  defp cost(%{model: model} = req, %{} = prices) when is_binary(model) do
    cost = Usage.cost(req, prices)
    if cost > 0, do: cost, else: 0.0
  rescue
    _ -> 0.0
  end

  defp cost(_req, _prices), do: 0.0

  defp tools(%{tools: same}, %{tools: same}, s), do: {[], s}

  defp tools(old, new, s) do
    changed = for {tool, c} <- new.tools, old.tools[tool] != c, do: {named(tool), c}

    {items, names} =
      changed
      |> Enum.reject(&(elem(&1, 0) == ""))
      |> Enum.sort()
      |> Enum.reduce({[], s.tools}, fn {name, c}, {items, names} ->
        if MapSet.member?(names, name) or MapSet.size(names) < @tool_limit do
          body = %Proto.ToolTally{name: name, calls: count(c.calls), errors: count(c.errors)}
          {[{:tool, body} | items], MapSet.put(names, name)}
        else
          {items, names}
        end
      end)

    # Every tool that goes out under no name of its own, added up.
    other =
      Enum.reduce(new.tools, {0, 0}, fn {tool, c}, {calls, errors} ->
        if MapSet.member?(names, named(tool)),
          do: {calls, errors},
          else: {calls + count(c.calls), errors + count(c.errors)}
      end)

    items =
      if other == s.other do
        items
      else
        {calls, errors} = other

        [
          {:tool, %Proto.ToolTally{name: @other, calls: count(calls), errors: count(errors)}}
          | items
        ]
      end

    {Enum.reverse(items), %{s | tools: names, other: other}}
  end

  # A tool's name as it may leave, or "" for one that is counted under
  # `other`. A tool really called that is counted there too, so the name
  # means one thing.
  defp named(tool) do
    case tool_name(tool) do
      @other -> ""
      name -> name
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

    body = %Proto.Summary{
      title: text(t.titles[:custom] || t.titles[:agent] || s.ctx[:title] || t.titles[:ai]),
      first_prompt: text(t.first_prompt),
      last_prompt: text(t.last_prompt),
      folder: text(t.cwd),
      branch: text(t.git_branch, 200),
      repo: repo,
      prs: prs(t.prs),
      model: model(t.model),
      effort: effort(t.effort),
      version: version(t.version),
      entrypoint: entrypoint(t.entrypoint)
    }

    {body, s}
  end

  # Asked again only when the folder changes: it reads the folder's git
  # config. Only for a whole path, so a made-up folder never points it at
  # the collector's own.
  defp repo(cwd, %{repo: {cwd, repo}} = s), do: {repo, s}

  defp repo(cwd, s) do
    find = s.ctx[:repo] || (&GitRemote.github_repo/1)

    repo =
      if is_binary(cwd) and text(cwd, 4096) == cwd and Path.type(cwd) == :absolute do
        try do
          repo_name(find.(cwd))
        rescue
          _ -> ""
        catch
          _, _ -> ""
        end
      else
        ""
      end

    {repo, %{s | repo: {cwd, repo}}}
  end

  defp prs(prs) do
    prs
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
    |> Enum.flat_map(fn url ->
      pattern =
        ~r"\Ahttps://github\.com/([A-Za-z0-9_.-]{1,100})/([A-Za-z0-9_.-]{1,100})/pull/([0-9]{1,9})\z"

      case Regex.run(pattern, url) do
        [_, owner, name, number] ->
          [
            %Proto.PullRequest{
              url: url,
              number: String.to_integer(number),
              repo: owner <> "/" <> name
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.take(@pr_limit)
  end

  # The item for a total, when the tally under it changed and the total is
  # not as last sent. `build` takes the tally, and the state when it needs it.
  defp changed(old, new, s, key, keys, build) do
    if Enum.all?(keys, &(Map.get(old, &1) == Map.get(new, &1))) do
      {[], s}
    else
      {body, s} =
        if is_function(build, 2), do: build.(new, s), else: {build.(new), s}

      if Map.fetch!(s, key) == body, do: {[], s}, else: {[{key, body}], Map.put(s, key, body)}
    end
  end

  defp event(ctx, file, position, at, helper?, items) do
    check_key!(ctx)

    %Proto.Event{
      session_id: ctx.session_id,
      file: file,
      position: position,
      at: at,
      subagent: helper?,
      items: Enum.map(items, &%Proto.Item{body: &1})
    }
  end

  defp check_key!(%{session_id: id} = ctx) do
    file = ctx[:file] || ""

    cond do
      id(id) != id or id == "" ->
        raise ArgumentError, "not a session id: #{inspect(id)}"

      not is_binary(file) or byte_size(file) > 1024 or text(file, 1024) != file ->
        raise ArgumentError, "not a session file name: #{inspect(file)}"

      true ->
        :ok
    end
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

  # Allowed free text. Line breaks become spaces, characters that do not
  # show are taken out (control and formatting characters, the invisible
  # "tag" letters, blank fillers and variation marks, which could carry
  # hidden text), and what is left is cut by counting characters one by one.
  defp text(s, limit \\ @text_limit)

  defp text(s, limit) when is_binary(s) do
    if String.valid?(s) do
      points =
        s
        |> String.replace(~r/\s+/u, " ")
        |> String.replace(
          ~r/[\p{C}\x{034F}\x{115F}\x{1160}\x{180B}-\x{180F}\x{3164}\x{FFA0}\x{FE00}-\x{FE0F}\x{E0100}-\x{E01EF}]/u,
          ""
        )
        |> String.trim()
        |> String.codepoints()

      if length(points) > limit,
        do: Enum.join(Enum.take(points, limit - 1)) <> "…",
        else: Enum.join(points)
    else
      ""
    end
  end

  defp text(_, _), do: ""

  # Each kind of name has its own shape. Anything else is dropped whole.
  defp model(s), do: shaped(s, ~r"\A[a-z0-9][a-z0-9.\[\]-]{0,63}\z")
  defp effort(s), do: shaped(s, ~r"\A[a-z]{1,16}\z")
  defp version(s), do: shaped(s, ~r"\A[0-9][0-9A-Za-z.+-]{0,31}\z")
  defp account(s), do: shaped(s, ~r"\A[A-Za-z0-9_.-]{1,64}\z")
  defp id(s), do: shaped(s, ~r"\A[A-Za-z0-9_-]{1,100}\z")
  # GitHub's runner names: letters, digits, dot, underscore and hyphen.
  defp runner_name(s), do: shaped(s, ~r"\A[A-Za-z0-9._-]{1,64}\z")

  defp entrypoint(s),
    do: shaped(s, ~r"\A[A-Za-z][A-Za-z_-]{0,19}( [A-Za-z][A-Za-z_-]{0,19})?\z")

  defp tool_name(s) do
    shaped(
      s,
      ~r"\A([A-Za-z][A-Za-z0-9_]{0,39}|mcp__[A-Za-z0-9_.-]{1,60}__[A-Za-z0-9_.-]{1,60})\z"
    )
  end

  defp shaped(s, pattern) when is_binary(s), do: if(s =~ pattern, do: s, else: "")
  defp shaped(_, _), do: ""

  # An id of another shape still has to tell its request from the others,
  # so it leaves as a hash of itself. A reply with no id at all is told
  # apart by where its line is.
  defp request_id(id, position) do
    case id(id) do
      "" ->
        id = if is_nil(id), do: {nil, position}, else: id
        hash = :crypto.hash(:sha256, :erlang.term_to_binary(id))
        "h-" <> binary_part(Base.encode16(hash, case: :lower), 0, 16)

      plain ->
        plain
    end
  end

  defp repo_name(s) when is_binary(s) do
    if s =~ ~r"\A[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}\z", do: s, else: ""
  end

  defp repo_name(_), do: ""

  defp count(n) when is_integer(n) and n > 0, do: min(n, @max)
  defp count(n) when is_float(n) and n >= @max, do: @max
  defp count(n) when is_float(n) and n > 0, do: round(n)
  defp count(_), do: 0

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)
  defp unix(_), do: 0
end
