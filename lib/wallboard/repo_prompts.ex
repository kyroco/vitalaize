defmodule Wallboard.RepoPrompts do
  @moduledoc """
  Notices agent work in a GitHub repository the Git tab does not follow,
  and asks the owner once, in the mailbox, whether to track it (see
  `Wallboard.Mailbox.NewRepo`).

  ## Where the work is seen

    * On this hub's own machine: the folders of its Claude and Codex
      sessions, each read for its GitHub origin
      (`Wallboard.GitRemote.github_repo/1`).
    * On other machines: the repository a collector names in a session's
      summary (see `Wallboard.Collector.Filter`), for lines written in the
      last 12 hours, so the first days of history a new collector sends
      ask nothing.

  A folder with no GitHub origin names no repository, so it never asks.

  ## One ask for each repository

  However many sessions or machines work in a repository, it has one ask,
  which lists up to 5 of the machines. Names are compared without case,
  as GitHub does.

  Before an ask shows, the hub's own GitHub login is asked whether it can
  see the repository. When it can, the ask offers Track and Ignore. When
  GitHub answers that there is no such repository for this login, or
  refuses the login for it, the ask says so and offers only Ignore. When
  GitHub cannot be asked at all (no `gh`, no network, a login that ran
  out), the ask waits and the question is put again every few minutes: a
  board that cannot reach GitHub has no Git tab to add to. After a day of
  that the ask gives up its place, and comes back when work is seen there
  again.

  A repository that was renamed answers under its name now. The ask is
  then about that name, and there is none when the board follows or
  ignores it already.

    * **Track** adds the repository to the end of the board's list
      (`Wallboard.Settings.track_repo/1`), and the Git tab picks it up.
    * **Ignore** is remembered, so the repository never asks again. The
      settings page lists what was ignored, each with "Ask again".

  A repository added to the settings by hand drops its ask. An ask nobody
  answered leaves a week after work was last seen there.

  ## Limits

  A machine that streams to the hub chooses the names it sends, so: a name
  must look like owner/name, at most 10 asks wait at once, at most 5
  of them first seen on any one machine, and each new name costs one
  question to GitHub. Past the limit a repository is not asked about until
  there is room. A collector names a session's repository once, not with
  every line, so the hub keeps what streams told of in the last 12 hours
  (in memory, the newest 200) and goes over it again when room is made, on
  Ask again, and every few minutes.

  ## Saved

  The asks and the ignored list are kept in the database, so both are
  still there after a restart. Until they have been read, nothing is asked
  and nothing is saved, so a database that is slow to answer never costs
  the ignored list.
  """

  use GenServer

  alias Wallboard.Collector.Proto
  alias Wallboard.{Cmd, GitRemote, Mailbox, Poller, Settings, Store}

  @meta "repo_prompts"
  @max_asks 10
  @max_per_machine 5
  @max_machines 5
  @max_ignored 500
  @recent_seconds 12 * 3600
  @forget_seconds 7 * 24 * 3600
  @hidden_again_seconds 3600
  @unknown_seconds 24 * 3600
  @tick_ms 5 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The asks ready to show, oldest first: `%{id, repo, machines, visible?}`.
  `visible?` is false when the hub's GitHub login cannot see the repository.
  """
  def pending do
    GenServer.call(__MODULE__, :pending, 5_000)
  catch
    :exit, _ -> []
  end

  @doc "The repositories the owner chose to ignore, by name, in a-to-z order."
  def ignored do
    GenServer.call(__MODULE__, :ignored, 5_000)
  catch
    :exit, _ -> []
  end

  @doc "Adds the repository of the ask `id` to the board's list. `{:error, :gone}` when there is no such ask to track."
  def track(id), do: call({:track, id})

  @doc "Remembers the repository of the ask `id` as ignored."
  def ignore(id), do: call({:ignore, id})

  @doc "Takes a repository off the ignored list, so work there asks again."
  def ask_again(repo), do: call({:ask_again, repo})

  @doc "Notes work in `repo` on `machine`, as the hub's own sessions and the stream do."
  def seen(repo, machine), do: GenServer.cast(__MODULE__, {:seen, repo, machine})

  defp call(message) do
    GenServer.call(__MODULE__, message, 60_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Asks the hub's GitHub login about a repository: `{:visible, name}` with
  the name as GitHub spells it, `:hidden` when GitHub says this login has
  no such repository, or `:unknown` when GitHub could not be asked.
  """
  def look(repo) do
    "gh"
    |> Cmd.run(["api", "repos/" <> repo, "--jq", ".full_name"], timeout: 30_000)
    |> sight()
  end

  @doc "What `look/1` makes of the command's result."
  def sight({:ok, out}), do: {:visible, String.trim(out)}

  # gh ends its complaint with the status: "gh: Not Found (HTTP 404)". A
  # private repository this login is not in is "not found" as well. 403 is
  # GitHub refusing this login for that repository (an organization that
  # wants single sign-on, say), unless it is the hourly limit, which
  # passes. 401 is a login GitHub no longer takes: that is about the
  # login, not the repository, so it is not an answer.
  def sight({:error, reason}) when is_binary(reason) do
    cond do
      reason =~ "(HTTP 404)" -> :hidden
      reason =~ "(HTTP 403)" and not (reason =~ ~r/rate limit/i) -> :hidden
      true -> :unknown
    end
  end

  def sight(_), do: :unknown

  @doc """
  True for a name this module will ask about: owner/name in the letters
  GitHub allows, with nothing before or after, and never a "." or ".."
  part, which would turn the question to GitHub into one about something
  else.
  """
  def name?(name) do
    is_binary(name) and byte_size(name) <= 140 and
      name =~ ~r{\A[A-Za-z0-9_][A-Za-z0-9_-]*/[A-Za-z0-9._-]+\z} and
      (name |> String.split("/") |> List.last()) not in [".", ".."]
  end

  @doc "Looks at the settings again now, after the repository list changed there."
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Wallboard.PubSub, "link")
    Phoenix.PubSub.subscribe(Wallboard.PubSub, Poller.topic())

    state = %{
      loaded?: false,
      # lower-case name => %{repo, machines, by, first_at, seen_at, sight,
      #   checking?, checked_at}. `sight` is :unknown until GitHub answered.
      asks: %{},
      # Names, oldest first.
      ignored: [],
      # A running question to GitHub: task ref => lower-case name.
      checks: %{},
      # Work a stream told of lately: {lower-case name, machine} => {name,
      # when}. A collector names a session's repository once, not with
      # every line, so this is what a repository that found no room, or
      # was taken off the ignored list, is asked about from.
      recent: %{},
      # A name GitHub answered under another name (a renamed repository):
      # lower-case name => the lower-case name GitHub gave.
      same_as: %{},
      # What the database holds, to save only a change.
      saved: nil,
      # What the mailbox last showed, to announce only a change.
      shown: [],
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      look: Keyword.get(opts, :look, &look/1),
      track: Keyword.get(opts, :track, &Settings.track_repo/1),
      tracked: Keyword.get(opts, :tracked, &tracked/0),
      hub: Keyword.get(opts, :hub, &hub_name/0),
      local: Keyword.get(opts, :local, &local_folders/0)
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:pending, _from, state), do: {:reply, view(state), state}

  def handle_call(:ignored, _from, state),
    do: {:reply, Enum.sort_by(state.ignored, &String.downcase/1), state}

  def handle_call(message, from, %{loaded?: false} = state) do
    state = load(state)

    if state.loaded?,
      do: handle_call(message, from, state),
      else: {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:track, id}, _from, state) do
    case state.asks[id] do
      %{sight: :visible, repo: repo} ->
        case safely(fn -> state.track.(repo) end) do
          # The room this leaves goes to a repository that found none.
          :ok -> {:reply, :ok, state |> drop(id) |> again() |> settle()}
          _ -> {:reply, {:error, :not_saved}, state}
        end

      _ ->
        {:reply, {:error, :gone}, state}
    end
  end

  def handle_call({:ignore, id}, _from, state) do
    case state.asks[id] do
      %{repo: repo} ->
        # Under the name it was seen by as well, when GitHub gave another.
        names = Enum.uniq_by([repo | if(name?(id), do: [id], else: [])], &key/1)
        keys = Enum.map(names, &key/1)

        ignored =
          Enum.take(Enum.reject(state.ignored, &(key(&1) in keys)) ++ names, -@max_ignored)

        {:reply, :ok, %{state | ignored: ignored} |> drop(id) |> again() |> settle()}

      _ ->
        {:reply, {:error, :gone}, state}
    end
  end

  def handle_call({:ask_again, repo}, _from, state) when is_binary(repo) do
    ignored = Enum.reject(state.ignored, &(key(&1) == key(repo)))
    {:reply, :ok, %{state | ignored: ignored} |> again() |> settle()}
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :gone}, state}

  @impl true
  def handle_cast({:seen, repo, machine}, state),
    do: {:noreply, state |> load() |> sightings([{repo, machine}]) |> settle()}

  def handle_cast(:refresh, state), do: {:noreply, state |> load() |> prune() |> settle()}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick_ms)

    state =
      state
      |> load()
      |> sightings(local(state))
      |> again()
      |> prune()
      |> look_again()
      |> settle()

    {:noreply, state}
  end

  # What a collector's stream saved (see `Wallboard.Link.Hub`). A row says
  # its kind and its time, so only a file's recent lines are opened.
  def handle_info({:link, :events, machine, rows}, state) when is_binary(machine) do
    now = System.os_time(:second)
    floor = now - @recent_seconds

    seen =
      for %{event: bytes} = row <- rows,
          Map.get(row, :kind, "file") == "file",
          Map.get(row, :at, now) >= floor,
          %Proto.Event{at: at, items: items} <- decode(bytes),
          at >= floor,
          %Proto.Item{body: {:summary, %Proto.Summary{repo: repo}}} <- items,
          name?(repo),
          uniq: true,
          do: {repo, machine}

    {:noreply, state |> load() |> remember(seen, now) |> sightings(seen) |> settle()}
  end

  # The hub's own sessions changed.
  def handle_info({:source, name, facts, _meta}, state) when name in [:claude, :codex] do
    hub = state.hub.()
    seen = for folder <- folders(facts), repo = GitRemote.github_repo(folder), do: {repo, hub}
    {:noreply, state |> load() |> sightings(Enum.uniq(seen)) |> settle()}
  end

  # GitHub's answer about one repository.
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> answered(ref, result) |> settle()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, state |> answered(ref, :unknown) |> settle()}

  def handle_info(_, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------

  defp key(name), do: String.downcase(name)

  defp tracked, do: Settings.repo_names(Settings.get())

  defp hub_name, do: Wallboard.Archive.Collector.machine(Settings.get())

  # The folders of the sessions on this machine now.
  defp local_folders do
    for name <- [:claude, :codex], folder <- folders(Poller.snapshot(name).facts), do: folder
  end

  defp folders(%{sessions: sessions}) when is_list(sessions),
    do: for(%{cwd: cwd} when is_binary(cwd) <- sessions, uniq: true, do: cwd)

  defp folders(_), do: []

  defp local(state) do
    hub = state.hub.()

    for folder <- state.local.(), repo = GitRemote.github_repo(folder), uniq: true do
      {repo, hub}
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp decode(bytes) do
    [Proto.Event.decode(bytes)]
  rescue
    _ -> []
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # Work seen in these repositories, each `{name, machine}`.
  defp sightings(%{loaded?: false} = state, _seen), do: state
  defp sightings(state, []), do: state

  defp sightings(state, seen) do
    following = following(state)
    ignored = MapSet.new(state.ignored, &key/1)
    now = System.os_time(:second)

    Enum.reduce(seen, state, fn {repo, machine}, state ->
      id = is_binary(repo) && key(repo)
      # The name GitHub knows it by, when that is another.
      other = id && state.same_as[id]

      cond do
        not name?(repo) or not is_binary(machine) ->
          state

        MapSet.member?(ignored, id) or MapSet.member?(ignored, other) ->
          state

        MapSet.member?(following, id) or MapSet.member?(following, other) ->
          drop(state, id)

        ask = state.asks[id] ->
          machines = Enum.take(Enum.uniq(ask.machines ++ [machine]), @max_machines)
          put_in(state.asks[id], %{ask | machines: machines, seen_at: hour(now)})

        map_size(state.asks) >= @max_asks or
            Enum.count(state.asks, fn {_, a} -> a.by == machine end) >= @max_per_machine ->
          state

        true ->
          ask = %{
            repo: repo,
            machines: [machine],
            by: machine,
            first_at: now,
            seen_at: hour(now),
            sight: :unknown,
            checking?: false,
            checked_at: nil
          }

          check(put_in(state.asks[id], ask), id)
      end
    end)
  end

  # The repositories the board follows, by lower-case name.
  defp following(state) do
    case safely(state.tracked) do
      list when is_list(list) ->
        for name <- list, is_binary(name), into: MapSet.new(), do: key(name)

      _ ->
        MapSet.new()
    end
  end

  # Keeps what a stream told of, for `again/1`. The newest 200.
  defp remember(%{loaded?: false} = state, _seen, _now), do: state

  defp remember(state, seen, now) do
    recent =
      Enum.reduce(seen, state.recent, fn {repo, machine}, recent ->
        Map.put(recent, {key(repo), machine}, {repo, now})
      end)

    recent =
      if map_size(recent) > 200,
        do: recent |> Enum.sort_by(fn {_, {_, at}} -> -at end) |> Enum.take(200) |> Map.new(),
        else: recent

    %{state | recent: recent}
  end

  # Goes over the work streams told of in the last 12 hours once more.
  defp again(%{loaded?: false} = state), do: state

  defp again(state) do
    floor = System.os_time(:second) - @recent_seconds
    recent = Map.filter(state.recent, fn {_, {_, at}} -> at >= floor end)

    seen =
      recent
      |> Enum.sort_by(fn {_, {_, at}} -> at end)
      |> Enum.map(fn {{_, machine}, {repo, _}} -> {repo, machine} end)

    sightings(%{state | recent: recent}, seen)
  end

  # To the hour, so the time work was last seen is saved once an hour at most.
  defp hour(seconds), do: seconds - rem(seconds, 3600)

  defp drop(state, id), do: %{state | asks: Map.delete(state.asks, id)}

  # Asks the hub's GitHub login, away from this process: `gh` can take a while.
  defp check(state, id) do
    %{repo: repo} = state.asks[id]
    look = state.look
    task = Task.Supervisor.async_nolink(Wallboard.TaskSupervisor, fn -> look.(repo) end)

    state = put_in(state.asks[id].checking?, true)
    %{state | checks: Map.put(state.checks, task.ref, id)}
  end

  defp answered(state, ref, result) do
    {id, checks} = Map.pop(state.checks, ref)
    state = %{state | checks: checks}

    case id && state.asks[id] do
      %{} = ask ->
        ask = %{ask | checking?: false, checked_at: System.os_time(:second)}

        case result do
          {:visible, name} when is_binary(name) ->
            visible(state, id, ask, name)

          :hidden ->
            put_in(state.asks[id], %{ask | sight: :hidden})

          _ ->
            put_in(state.asks[id], ask)
        end

      _ ->
        state
    end
  end

  # GitHub can see it, under `name`. That is the asked name in GitHub's own
  # spelling, or, for a repository that was renamed or moved, its name now:
  # then the ask is about that one, and goes if the board follows or
  # ignores it already.
  defp visible(state, id, ask, name) do
    now_id = key(name)

    cond do
      now_id == id ->
        put_in(state.asks[id], %{ask | sight: :visible, repo: name})

      not name?(name) ->
        put_in(state.asks[id], %{ask | sight: :visible})

      true ->
        same_as = state.same_as |> Enum.take(199) |> Map.new() |> Map.put(id, now_id)
        state = %{state | same_as: same_as}
        known? = now_id in Enum.map(state.ignored, &key/1) or now_id in following(state)

        if known? or Map.has_key?(state.asks, now_id),
          do: drop(state, id),
          else: put_in(state.asks[id], %{ask | sight: :visible, repo: name})
    end
  end

  # Asks tracked by hand since, asks nobody answered for a week, and asks
  # GitHub could not be asked about for a day: those make room, and come
  # back when work is seen there again.
  defp prune(%{loaded?: false} = state), do: state

  defp prune(state) do
    following = following(state)
    now = System.os_time(:second)

    asks =
      Map.reject(state.asks, fn {id, ask} ->
        MapSet.member?(following, id) or MapSet.member?(following, key(ask.repo)) or
          ask.seen_at < hour(now - @forget_seconds) or
          (ask.sight == :unknown and ask.first_at < now - @unknown_seconds)
      end)

    %{state | asks: asks}
  end

  # GitHub could not be asked last time, or said no an hour ago: a login
  # can be given the repository since.
  defp look_again(state) do
    now = System.os_time(:second)

    Enum.reduce(state.asks, state, fn {id, ask}, state ->
      due? =
        not ask.checking? and
          (ask.sight == :unknown or
             (ask.sight == :hidden and now - (ask.checked_at || 0) >= @hidden_again_seconds))

      if due?, do: check(state, id), else: state
    end)
  end

  defp view(state) do
    following = following(state)

    state.asks
    |> Enum.filter(fn {id, ask} ->
      ask.sight != :unknown and not MapSet.member?(following, id) and
        not MapSet.member?(following, key(ask.repo))
    end)
    |> Enum.sort_by(fn {id, ask} -> {ask.first_at, id} end)
    |> Enum.map(fn {id, ask} ->
      %{id: id, repo: ask.repo, machines: ask.machines, visible?: ask.sight == :visible}
    end)
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Saved in the database

  defp load(%{loaded?: true} = state), do: state

  defp load(state) do
    case safely(fn -> {:ok, Store.get_meta(@meta)} end) do
      {:ok, text} ->
        {asks, ignored} = parse(text)
        state = %{state | loaded?: true, asks: asks, ignored: ignored}
        %{state | saved: dump(state), shown: view(state)}

      _ ->
        state
    end
  end

  defp parse(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} ->
        ignored =
          for name <- List.wrap(map["ignored"]), name?(name), uniq: true, do: name

        asks =
          for %{"repo" => repo} = a <- List.wrap(map["asks"]), name?(repo), into: %{} do
            machines = for m <- List.wrap(a["machines"]), is_binary(m), do: m

            {key(repo),
             %{
               repo: repo,
               machines: Enum.take(machines, @max_machines),
               by: if(is_binary(a["by"]), do: a["by"], else: List.first(machines)),
               first_at: whole(a["first_at"]),
               seen_at: whole(a["seen_at"]),
               sight: sight_word(a["sight"]),
               checking?: false,
               checked_at: nil
             }}
          end

        {asks |> Enum.take(@max_asks) |> Map.new(), Enum.take(ignored, -@max_ignored)}

      _ ->
        {%{}, []}
    end
  end

  defp parse(_), do: {%{}, []}

  defp whole(n) when is_integer(n), do: n
  defp whole(_), do: System.os_time(:second)

  defp sight_word("visible"), do: :visible
  defp sight_word("hidden"), do: :hidden
  defp sight_word(_), do: :unknown

  defp dump(state) do
    %{
      ignored: state.ignored,
      asks:
        state.asks
        |> Enum.sort()
        |> Enum.map(fn {_, a} ->
          Map.take(a, [:repo, :machines, :by, :first_at, :seen_at, :sight])
        end)
    }
  end

  # After every change: saves what differs from the database, and tells the
  # open boards when the mailbox's list differs.
  defp settle(%{loaded?: false} = state), do: state

  defp settle(state) do
    now = dump(state)

    state =
      if now != state.saved and safely(fn -> Store.put_meta(@meta, Jason.encode!(now)) end) == :ok,
        do: %{state | saved: now},
        else: state

    shown = view(state)
    if shown != state.shown, do: Mailbox.changed()
    %{state | shown: shown}
  end
end
