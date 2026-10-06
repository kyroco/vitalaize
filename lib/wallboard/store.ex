defmodule Wallboard.Store do
  @moduledoc """
  The board's own database: one SQLite file that keeps every Claude session
  after it is gone from `claude agents`, and after its transcript is deleted.

  This process is the only one that opens the file, so every save goes
  through it one at a time. That is also what lets other Macs feed it later:
  they send their sessions to this board, which saves them here, rather than
  sharing the file over the network (which can corrupt SQLite).

  Every row names the machine it came from, so one Mac can be both the hub
  that keeps the database and a collector of its own sessions.

  Times are stored as Unix seconds. Lists and small maps (tools used,
  subagents, pull requests) are stored as JSON text.
  """

  use GenServer
  require Logger

  alias Exqlite.Sqlite3

  # Each entry runs once, in order; the database remembers how many ran
  # (PRAGMA user_version). Add new ones at the end, never edit old ones.
  @migrations [
    """
    CREATE TABLE sessions (
      machine TEXT NOT NULL,
      session_id TEXT NOT NULL,
      account TEXT,
      transcript TEXT,
      title TEXT,
      cwd TEXT,
      git_branch TEXT,
      entrypoint TEXT,
      version TEXT,
      first_prompt TEXT,
      last_prompt TEXT,
      started_at INTEGER,
      ended_at INTEGER,
      model TEXT,
      effort TEXT,
      requests INTEGER,
      input_tokens INTEGER,
      output_tokens INTEGER,
      cache_read_tokens INTEGER,
      cache_write_tokens INTEGER,
      cost REAL,
      peak_context INTEGER,
      context_window INTEGER,
      prompts INTEGER,
      turns INTEGER,
      turn_ms INTEGER,
      api_ms INTEGER,
      tool_ms INTEGER,
      compactions INTEGER,
      api_errors INTEGER,
      retries INTEGER,
      aborted INTEGER,
      tool_calls INTEGER,
      tool_errors INTEGER,
      denials INTEGER,
      lines_added INTEGER,
      lines_removed INTEGER,
      files_touched INTEGER,
      subagents INTEGER,
      subagent_cost REAL,
      korium_searches INTEGER,
      korium_search_hits INTEGER,
      korium_saves INTEGER,
      korium_save_errors INTEGER,
      code_searches INTEGER,
      code_search_hits INTEGER,
      korium_index INTEGER,
      korium_other INTEGER,
      detail TEXT,
      source_size INTEGER,
      source_mtime INTEGER,
      captured_at INTEGER,
      deleted_at INTEGER,
      PRIMARY KEY (machine, session_id)
    )
    """,
    "CREATE INDEX sessions_ended ON sessions (ended_at)",
    """
    CREATE TABLE requests (
      machine TEXT NOT NULL,
      session_id TEXT NOT NULL,
      request_id TEXT NOT NULL,
      at INTEGER,
      model TEXT,
      effort TEXT,
      input_tokens INTEGER,
      output_tokens INTEGER,
      cache_read_tokens INTEGER,
      cache_write_tokens INTEGER,
      cost REAL,
      subagent INTEGER,
      PRIMARY KEY (machine, session_id, request_id)
    )
    """,
    "CREATE INDEX requests_at ON requests (at)",
    """
    CREATE TABLE status_events (
      machine TEXT NOT NULL,
      session_id TEXT NOT NULL,
      name TEXT,
      status TEXT NOT NULL,
      at INTEGER NOT NULL,
      PRIMARY KEY (machine, session_id, at, status)
    )
    """,
    """
    CREATE TABLE gh_runs (
      repo TEXT NOT NULL,
      run_id INTEGER NOT NULL,
      attempt INTEGER,
      workflow TEXT,
      name TEXT,
      event TEXT,
      branch TEXT,
      head_sha TEXT,
      status TEXT,
      conclusion TEXT,
      created_at INTEGER,
      started_at INTEGER,
      updated_at INTEGER,
      duration_s INTEGER,
      pr INTEGER,
      url TEXT,
      jobs_saved INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (repo, run_id)
    )
    """,
    "CREATE INDEX gh_runs_created ON gh_runs (created_at)",
    """
    CREATE TABLE gh_jobs (
      repo TEXT NOT NULL,
      job_id INTEGER NOT NULL,
      run_id INTEGER NOT NULL,
      attempt INTEGER,
      name TEXT,
      status TEXT,
      conclusion TEXT,
      created_at INTEGER,
      started_at INTEGER,
      completed_at INTEGER,
      queue_s INTEGER,
      duration_s INTEGER,
      runner_name TEXT,
      labels TEXT,
      failed_step TEXT,
      PRIMARY KEY (repo, job_id)
    )
    """,
    "CREATE INDEX gh_jobs_run ON gh_jobs (repo, run_id)",
    "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)",
    # Which tool ran the session: "claude" or "codex". Rows saved before
    # Codex was read are all Claude.
    "ALTER TABLE sessions ADD COLUMN tool TEXT DEFAULT 'claude'",
    # What collectors stream to the hub (see Wallboard.Link). One row per
    # event, as it arrived; a repeat lands on the same row. `kind` is file,
    # status or end. A status and an end come from no file and have no
    # position, so `kind` and `at` are part of the key: an end never shares
    # a row with a status, and two statuses of one second leave the later.
    """
    CREATE TABLE collector_events (
      machine TEXT NOT NULL,
      session_id TEXT NOT NULL,
      file TEXT NOT NULL,
      position INTEGER NOT NULL,
      at INTEGER NOT NULL,
      kind TEXT NOT NULL,
      received_at INTEGER NOT NULL,
      event BLOB NOT NULL,
      PRIMARY KEY (machine, session_id, file, position, at, kind)
    )
    """,
    # How far the hub got in each session file of each machine: what it
    # sends back in Resume.
    """
    CREATE TABLE collector_positions (
      machine TEXT NOT NULL,
      session_id TEXT NOT NULL,
      file TEXT NOT NULL,
      position INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (machine, session_id, file)
    )
    """,
    # What each machine said about itself in its last hello.
    """
    CREATE TABLE collector_machines (
      machine TEXT PRIMARY KEY,
      label TEXT,
      os TEXT,
      version TEXT,
      folders TEXT,
      seen_at INTEGER
    )
    """,
    # Where a saved session came from: "stream" (a collector's stream),
    # "upload" (a transcript another machine sent, before 0.3.0; those rows
    # are kept) or empty (this machine's own files). Uploads saved before
    # this column are known by their place in the inbox folder.
    "ALTER TABLE sessions ADD COLUMN source TEXT",
    "UPDATE sessions SET source = 'upload' WHERE transcript LIKE '%/inbox/%'",
    "CREATE INDEX sessions_session ON sessions (session_id)",
    # For finding the sessions heard from lately when the hub starts.
    "CREATE INDEX collector_events_received ON collector_events (received_at)"
  ]

  # The columns of `sessions`, in the order a saved session map fills them.
  @session_columns ~w(machine session_id account transcript title cwd git_branch entrypoint
    version first_prompt last_prompt started_at ended_at model effort requests input_tokens
    output_tokens cache_read_tokens cache_write_tokens cost peak_context context_window prompts
    turns turn_ms api_ms tool_ms compactions api_errors retries aborted tool_calls tool_errors
    denials lines_added lines_removed files_touched subagents subagent_cost korium_searches
    korium_search_hits korium_saves korium_save_errors code_searches code_search_hits
    korium_index korium_other detail source_size source_mtime captured_at deleted_at tool
    source)a

  @run_columns ~w(repo run_id attempt workflow name event branch head_sha status conclusion
    created_at started_at updated_at duration_s pr url)a

  @job_columns ~w(repo job_id run_id attempt name status conclusion created_at started_at
    completed_at queue_s duration_s runner_name labels failed_step)a

  @request_columns ~w(machine session_id request_id at model effort input_tokens output_tokens
    cache_read_tokens cache_write_tokens cost subagent)a

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # ---------------------------------------------------------------------------
  # Saving

  @doc """
  Saves one session and its requests, replacing what was saved for it
  before. `session` has the keys in @session_columns (missing ones are
  saved empty); `detail` may be a map, saved as JSON.

  A session whose `source` is "stream" also removes the copies of it that
  were uploaded as transcripts, under any machine name, so a session that
  arrives both ways is counted once.
  """
  def put_session(session, requests \\ []),
    do: GenServer.call(__MODULE__, {:put_session, session, requests}, 30_000)

  @doc "Marks sessions whose transcripts are gone, keeping everything saved."
  def mark_deleted(machine, session_ids, at),
    do: GenServer.call(__MODULE__, {:mark_deleted, machine, session_ids, at}, 30_000)

  @doc "Records a status change (working, needs, idle, gone) seen on the board."
  def put_status(machine, session_id, name, status, at),
    do: GenServer.cast(__MODULE__, {:put_status, machine, session_id, name, status, at})

  @doc """
  Saves GitHub runs. A run whose attempt or status changed since it was last
  saved has its jobs fetched again (a rerun, or a run that finished).
  """
  def put_runs(runs), do: GenServer.call(__MODULE__, {:put_runs, runs}, 30_000)

  @doc "Saves one run's jobs and marks the run's jobs as saved."
  def put_jobs(repo, run_id, jobs),
    do: GenServer.call(__MODULE__, {:put_jobs, repo, run_id, jobs}, 30_000)

  @doc """
  A run's saved jobs, or nil when none are saved for this attempt of it.
  A rerun keeps the jobs it did not run again under the earlier attempt,
  so the saved jobs are this attempt's when the newest of them is. With
  no attempt given, any saved jobs do. Jobs not all done are never this
  finished run's (see `GitHubCollector.final_jobs?/2`).
  """
  def run_jobs(repo, run_id, attempt) do
    jobs = query("SELECT * FROM gh_jobs WHERE repo = ?1 AND run_id = ?2", [repo, run_id])
    newest = jobs |> Enum.map(& &1.attempt) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

    if jobs != [] and (is_nil(attempt) or is_nil(newest) or newest == attempt) and
         Wallboard.Archive.GitHubCollector.final_jobs?(jobs, attempt),
       do: jobs
  end

  @doc "Finished runs whose jobs are not saved yet, newest first."
  def runs_missing_jobs(repo, limit) do
    query(
      """
      SELECT run_id FROM gh_runs
      WHERE repo = ?1 AND status = 'completed' AND jobs_saved = 0
      ORDER BY created_at DESC LIMIT ?2
      """,
      [repo, limit]
    )
    |> Enum.map(& &1.run_id)
  end

  @doc "How many finished runs still wait for their jobs to be saved."
  def runs_missing_jobs_count(repo) do
    case query(
           "SELECT count(*) AS n FROM gh_runs WHERE repo = ?1 AND status = 'completed' AND jobs_saved = 0",
           [repo]
         ) do
      [%{n: n}] -> n
      _ -> 0
    end
  end

  @doc "A small saved setting, such as how far the GitHub backfill got."
  def get_meta(key) do
    case query("SELECT value FROM meta WHERE key = ?1", [key]) do
      [%{value: v}] -> v
      _ -> nil
    end
  end

  def put_meta(key, value), do: GenServer.call(__MODULE__, {:put_meta, key, value}, 30_000)

  @doc """
  Saves events a collector sent, under the machine its certificate names,
  and moves that machine's position in each file forward. All of them or
  none, and on the disk before this returns. `events` are maps with
  `session_id`, `file`, `position`, `at`, `kind` ("file", "status" or
  "end") and `event` (the encoded message).

  Once they are saved, the same step says so on the `"link"` topic, as
  `{:link, :events, machine, events}`. The saving and the saying happen
  here, in the database's own process, so whoever asked for the save can
  stop at any moment without leaving events saved and unannounced. Events
  saved a second time are announced a second time.
  """
  def put_collector_events(machine, events, now),
    do: GenServer.call(__MODULE__, {:put_collector_events, machine, events, now}, 30_000)

  @doc "Saves what a machine said about itself in its hello."
  def put_collector_machine(machine, info, now),
    do: GenServer.call(__MODULE__, {:put_collector_machine, machine, info, now}, 30_000)

  # ---------------------------------------------------------------------------
  # Reading

  @doc "What was captured of each transcript on a machine: %{path => {size, mtime}}."
  def captured(machine) do
    "SELECT transcript, source_size, source_mtime FROM sessions WHERE machine = ?1 AND deleted_at IS NULL"
    |> query([machine])
    |> Map.new(fn r -> {r.transcript, {r.source_size, r.source_mtime}} end)
  end

  @doc """
  The hub's position in each of a machine's session files that moved since
  `since`, newest first, `limit` at most: `%{session_id, file, position}`.
  """
  def collector_positions(machine, since, limit) do
    query(
      """
      SELECT session_id, file, position FROM collector_positions
      WHERE machine = ?1 AND updated_at >= ?2
      ORDER BY updated_at DESC LIMIT ?3
      """,
      [machine, since, limit]
    )
  end

  @doc """
  A machine's saved events, in the order they were first saved. An event
  sent again keeps its place and the time it first arrived.
  """
  def collector_events(machine) do
    query(
      "SELECT session_id, file, position, at, kind, received_at, event FROM collector_events WHERE machine = ?1 ORDER BY rowid",
      [machine]
    )
  end

  @doc "Every machine that has said hello: `%{machine, label, os, version, folders, seen_at}`."
  def collector_machines do
    "SELECT machine, label, os, version, folders, seen_at FROM collector_machines ORDER BY machine"
    |> query([])
    |> Enum.map(fn m ->
      case decode(m.folders) do
        folders when is_list(folders) -> %{m | folders: folders}
        _ -> %{m | folders: []}
      end
    end)
  end

  @doc "One session's saved events from a machine, in the order they were first saved."
  def collector_events(machine, session_id) do
    query(
      "SELECT session_id, file, position, at, kind, received_at, event FROM collector_events WHERE machine = ?1 AND session_id = ?2 ORDER BY rowid",
      [machine, session_id]
    )
  end

  @doc "The sessions a collector sent anything for since `since`: `%{machine, session_id}`."
  def collector_sessions(since) do
    query(
      "SELECT DISTINCT machine, session_id FROM collector_events WHERE received_at >= ?1",
      [since]
    )
  end

  @doc """
  When each machine last sent a line of a session file, and how many of its
  sessions sent one since `since`: `%{machine => %{last, sessions}}`.
  """
  def collector_activity(since) do
    """
    SELECT machine, max(updated_at) AS last,
           count(DISTINCT CASE WHEN updated_at >= ?1 THEN session_id END) AS sessions
    FROM collector_positions GROUP BY machine
    """
    |> query([since])
    |> Map.new(&{&1.machine, %{last: &1.last, sessions: &1.sessions}})
  end

  @doc "The newest saved sessions, most recently active first, without their details."
  def list_sessions(limit \\ 120) do
    cols = Enum.reject(@session_columns, &(&1 == :detail)) |> Enum.join(", ")
    query("SELECT #{cols} FROM sessions ORDER BY ended_at DESC LIMIT ?1", [limit])
  end

  @doc "One saved session with its details decoded, its status history and requests per model."
  def get_session(machine, session_id) do
    case query("SELECT * FROM sessions WHERE machine = ?1 AND session_id = ?2", [
           machine,
           session_id
         ]) do
      [s] ->
        events =
          query(
            "SELECT status, at FROM status_events WHERE machine = ?1 AND session_id = ?2 ORDER BY at",
            [machine, session_id]
          )

        Map.merge(s, %{detail: decode(s.detail), events: events})

      [] ->
        nil
    end
  end

  @doc "How many sessions are saved, and how many of those were deleted from disk."
  def counts do
    [r] =
      query(
        "SELECT count(*) AS total, count(deleted_at) AS deleted, max(captured_at) AS last FROM sessions",
        []
      )

    r
  end

  @doc "Runs a read query and returns rows as maps with atom keys."
  def query(sql, params), do: GenServer.call(__MODULE__, {:query, sql, params}, 30_000)

  # ---------------------------------------------------------------------------
  # Server

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    if path != ":memory:", do: File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode = WAL")
    :ok = Sqlite3.execute(conn, "PRAGMA synchronous = NORMAL")
    # What collectors send is confirmed to them once it is saved (see
    # put_collector_events). Moving it from the log into the database file
    # must reach the drive too, which on a Mac only this setting ensures.
    :ok = Sqlite3.execute(conn, "PRAGMA checkpoint_fullfsync = ON")
    migrate(conn)
    Logger.info("Database: #{path}")
    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call({:put_session, session, requests}, _from, %{conn: c} = state) do
    session = Map.update(session, :detail, nil, &encode/1)

    result =
      transaction(c, fn ->
        if session[:source] == "stream", do: drop_uploaded(c, session)
        insert(c, "sessions", @session_columns, [session])

        run(c, "DELETE FROM requests WHERE machine = ?1 AND session_id = ?2", [
          session.machine,
          session.session_id
        ])

        insert(c, "requests", @request_columns, requests)
      end)

    {:reply, result, state}
  end

  def handle_call({:mark_deleted, machine, ids, at}, _from, %{conn: c} = state) do
    result =
      transaction(c, fn ->
        Enum.each(ids, fn id ->
          run(
            c,
            "UPDATE sessions SET deleted_at = ?3 WHERE machine = ?1 AND session_id = ?2 AND deleted_at IS NULL",
            [machine, id, at]
          )
        end)
      end)

    {:reply, result, state}
  end

  def handle_call({:put_runs, runs}, _from, %{conn: c} = state) do
    cols = Enum.join(@run_columns, ", ")
    marks = Enum.map_join(1..length(@run_columns), ", ", &"?#{&1}")
    updates = @run_columns |> Enum.drop(2) |> Enum.map_join(", ", &"#{&1} = excluded.#{&1}")

    sql = """
    INSERT INTO gh_runs (#{cols}) VALUES (#{marks})
    ON CONFLICT (repo, run_id) DO UPDATE SET #{updates},
      jobs_saved = CASE
        WHEN excluded.attempt IS NOT gh_runs.attempt OR excluded.status IS NOT gh_runs.status THEN 0
        ELSE gh_runs.jobs_saved END
    """

    result =
      transaction(c, fn ->
        Enum.each(runs, fn r -> run(c, sql, Enum.map(@run_columns, &Map.get(r, &1))) end)
      end)

    {:reply, result, state}
  end

  def handle_call({:put_jobs, repo, run_id, jobs}, _from, %{conn: c} = state) do
    result =
      transaction(c, fn ->
        run(c, "DELETE FROM gh_jobs WHERE repo = ?1 AND run_id = ?2", [repo, run_id])
        insert(c, "gh_jobs", @job_columns, jobs)

        run(c, "UPDATE gh_runs SET jobs_saved = 1 WHERE repo = ?1 AND run_id = ?2", [repo, run_id])
      end)

    {:reply, result, state}
  end

  def handle_call({:put_meta, key, value}, _from, %{conn: c} = state) do
    run(c, "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)", [key, value])
    {:reply, :ok, state}
  end

  def handle_call({:put_collector_events, machine, events, now}, _from, %{conn: c} = state) do
    # The collector forgets these once it is told they are saved, so this
    # one write waits for the disk. Everything else the board saves can be
    # read again from its source and keeps the faster setting.
    # (On a Mac only fullfsync makes the drive itself write it down.)
    :ok = Sqlite3.execute(c, "PRAGMA fullfsync = ON")
    :ok = Sqlite3.execute(c, "PRAGMA synchronous = FULL")

    result =
      transaction(c, fn ->
        Enum.each(events, fn e ->
          run(
            c,
            """
            INSERT INTO collector_events
              (machine, session_id, file, position, at, kind, received_at, event)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT (machine, session_id, file, position, at, kind)
              DO UPDATE SET event = excluded.event
            """,
            [machine, e.session_id, e.file, e.position, e.at, e.kind, now, {:blob, e.event}]
          )

          if e.file != "" do
            run(
              c,
              """
              INSERT INTO collector_positions (machine, session_id, file, position, updated_at)
              VALUES (?1, ?2, ?3, ?4, ?5)
              ON CONFLICT (machine, session_id, file) DO UPDATE SET
                position = max(position, excluded.position), updated_at = excluded.updated_at
              """,
              [machine, e.session_id, e.file, e.position, now]
            )
          end
        end)
      end)

    :ok = Sqlite3.execute(c, "PRAGMA synchronous = NORMAL")
    :ok = Sqlite3.execute(c, "PRAGMA fullfsync = OFF")
    if result == :ok, do: announce({:link, :events, machine, events})
    {:reply, result, state}
  end

  def handle_call({:put_collector_machine, machine, info, now}, _from, %{conn: c} = state) do
    run(
      c,
      """
      INSERT OR REPLACE INTO collector_machines (machine, label, os, version, folders, seen_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [machine, info[:label], info[:os], info[:version], encode(info[:folders] || []), now]
    )

    {:reply, :ok, state}
  end

  def handle_call({:query, sql, params}, _from, %{conn: c} = state),
    do: {:reply, rows(c, sql, params), state}

  @impl true
  def handle_cast({:put_status, machine, id, name, status, at}, %{conn: c} = state) do
    run(
      c,
      "INSERT OR IGNORE INTO status_events (machine, session_id, name, status, at) VALUES (?1, ?2, ?3, ?4, ?5)",
      [machine, id, name, to_string(status), at]
    )

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # SQLite helpers

  defp migrate(c) do
    [[done]] = rows_raw(c, "PRAGMA user_version", [])

    @migrations
    |> Enum.with_index(1)
    |> Enum.drop(done)
    |> Enum.each(fn {sql, n} ->
      :ok = Sqlite3.execute(c, sql)
      :ok = Sqlite3.execute(c, "PRAGMA user_version = #{n}")
    end)
  end

  defp transaction(c, fun) do
    :ok = Sqlite3.execute(c, "BEGIN")

    try do
      fun.()
      :ok = Sqlite3.execute(c, "COMMIT")
      :ok
    rescue
      e ->
        Sqlite3.execute(c, "ROLLBACK")
        Logger.error("Database write failed: " <> Exception.message(e))
        {:error, Exception.message(e)}
    end
  end

  # Nobody listening (a `mix` task, say) is no reason to fail a save.
  defp announce(message) do
    Phoenix.PubSub.broadcast(Wallboard.PubSub, "link", message)
  rescue
    _ -> :ok
  end

  # The uploaded copies of a session the stream now saves.
  defp drop_uploaded(c, %{machine: machine, session_id: id}) do
    twins = "session_id = ?1 AND source = 'upload' AND machine != ?2"

    run(
      c,
      "DELETE FROM requests WHERE session_id = ?1 AND machine IN (SELECT machine FROM sessions WHERE #{twins})",
      [id, machine]
    )

    run(c, "DELETE FROM sessions WHERE #{twins}", [id, machine])
  end

  defp insert(_c, _table, _cols, []), do: :ok

  defp insert(c, table, cols, rows) do
    marks = Enum.map_join(1..length(cols), ", ", &"?#{&1}")
    sql = "INSERT OR REPLACE INTO #{table} (#{Enum.join(cols, ", ")}) VALUES (#{marks})"
    {:ok, stmt} = Sqlite3.prepare(c, sql)

    try do
      Enum.each(rows, fn row ->
        :ok = Sqlite3.bind(stmt, Enum.map(cols, &value(Map.get(row, &1))))
        :done = Sqlite3.step(c, stmt)
        :ok = Sqlite3.reset(stmt)
      end)
    after
      Sqlite3.release(c, stmt)
    end
  end

  defp run(c, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(c, sql)

    try do
      :ok = Sqlite3.bind(stmt, Enum.map(params, &value/1))
      :done = Sqlite3.step(c, stmt)
    after
      Sqlite3.release(c, stmt)
    end
  end

  defp rows(c, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(c, sql)

    try do
      :ok = Sqlite3.bind(stmt, Enum.map(params, &value/1))
      {:ok, cols} = Sqlite3.columns(c, stmt)
      {:ok, rows} = Sqlite3.fetch_all(c, stmt)
      keys = Enum.map(cols, &String.to_atom/1)
      Enum.map(rows, &(keys |> Enum.zip(&1) |> Map.new()))
    after
      Sqlite3.release(c, stmt)
    end
  end

  defp rows_raw(c, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(c, sql)

    try do
      :ok = Sqlite3.bind(stmt, params)
      {:ok, rows} = Sqlite3.fetch_all(c, stmt)
      rows
    after
      Sqlite3.release(c, stmt)
    end
  end

  defp value(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp value(true), do: 1
  defp value(false), do: 0
  defp value(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp value(v), do: v

  defp encode(nil), do: nil
  defp encode(v) when is_binary(v), do: v
  defp encode(v), do: Jason.encode!(v)

  defp decode(nil), do: %{}

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, v} -> v
      _ -> %{}
    end
  end
end
