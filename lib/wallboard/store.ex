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
    "ALTER TABLE sessions ADD COLUMN tool TEXT DEFAULT 'claude'"
  ]

  # The columns of `sessions`, in the order a saved session map fills them.
  @session_columns ~w(machine session_id account transcript title cwd git_branch entrypoint
    version first_prompt last_prompt started_at ended_at model effort requests input_tokens
    output_tokens cache_read_tokens cache_write_tokens cost peak_context context_window prompts
    turns turn_ms api_ms tool_ms compactions api_errors retries aborted tool_calls tool_errors
    denials lines_added lines_removed files_touched subagents subagent_cost korium_searches
    korium_search_hits korium_saves korium_save_errors code_searches code_search_hits
    korium_index korium_other detail source_size source_mtime captured_at deleted_at tool)a

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

  # ---------------------------------------------------------------------------
  # Reading

  @doc "What was captured of each transcript on a machine: %{path => {size, mtime}}."
  def captured(machine) do
    "SELECT transcript, source_size, source_mtime FROM sessions WHERE machine = ?1 AND deleted_at IS NULL"
    |> query([machine])
    |> Map.new(fn r -> {r.transcript, {r.source_size, r.source_mtime}} end)
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
    migrate(conn)
    Logger.info("Database: #{path}")
    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call({:put_session, session, requests}, _from, %{conn: c} = state) do
    session = Map.update(session, :detail, nil, &encode/1)

    result =
      transaction(c, fn ->
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
