defmodule Wallboard.Runners do
  @moduledoc """
  Which machine ran a GitHub Actions job, one of GitHub's or one of your own
  (a self-hosted runner), and the state of each of your own runners.

  GitHub's own machines are in the runner group "GitHub Actions". A job
  ran on your own machine when it has the "self-hosted" label (in any letter
  case, as GitHub matches labels), or when its
  runner is one GitHub lists among the repository's own runners. A job in
  another group with neither is not known: GitHub's paid larger runners sit
  in groups too, and their minutes must not count as yours. Jobs saved
  before the board kept the group have only the runner's name, and GitHub
  names its own machines like "GitHub Actions 1000041223". Anything else is
  not known, and is never guessed.

  A runner's state comes from GitHub's list of the repository's runners when
  the board's GitHub login may read it (that needs admin rights on the
  repository), else from a collector on the runner's machine. Runners that
  ran the repository's jobs but that neither one reports are counted on one
  line, with the reason, not listed one by one: runners made for a single
  job leave a new name behind each time.

  Nothing here, or anywhere in the board, installs, starts, stops or changes
  a runner: it only reads.
  """

  @github_group "GitHub Actions"

  @doc """
  Whose machine ran a job: `:github`, `:own` or `:unknown`. `job` is a map
  with any of `runner_group_name`, `labels` (a list, or the saved text with
  commas) and `runner_name`, under string or atom keys. `listed` is the
  names of the repository's own runners GitHub lists, when known.
  """
  def kind(job, listed \\ []) do
    group = field(job, :runner_group_name)
    name = field(job, :runner_name)

    cond do
      group == @github_group -> :github
      "self-hosted" in labels(field(job, :labels)) -> :own
      is_binary(name) and name in listed -> :own
      is_binary(name) and Regex.match?(~r/\AGitHub Actions \d+\z/, name) -> :github
      true -> :unknown
    end
  end

  @doc "The names in GitHub's list of a repository's runners; none when it was not read."
  def listed_names(listed) when is_list(listed), do: Enum.map(listed, & &1.name)
  def listed_names(_), do: []

  defp field(job, key), do: Map.get(job, key) || Map.get(job, Atom.to_string(key))

  # Lowercased: GitHub matches a job's labels without regard to case, and so
  # does the SQL in `Wallboard.Archive.CiMinutes`.
  defp labels(list) when is_list(list), do: for(l <- list, is_binary(l), do: String.downcase(l))
  defp labels(text) when is_binary(text), do: text |> String.split(",", trim: true) |> labels()
  defp labels(_), do: []

  @doc """
  The names of your own runners that ran, or run, any of `jobs`, in the
  order they first appear.
  """
  def own_names(jobs, listed \\ []) do
    jobs
    |> Enum.filter(&(kind(&1, listed) == :own))
    |> Enum.map(&field(&1, :runner_name))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  @doc "What each of your own runners is running now: `%{name => job name}`."
  def busy(jobs, listed \\ []) do
    for job <- jobs,
        field(job, :status) == "in_progress",
        name = field(job, :runner_name),
        is_binary(name),
        kind(job, listed) == :own,
        into: %{},
        do: {name, field(job, :name)}
  end

  @doc """
  Each of a repository's own runners that GitHub lists or a collector
  reports, with its state, sorted by name: `%{name, state, job, from}`.

    * `listed` is GitHub's list of the repository's runners
      (`%{name, status, busy}` each), `:hidden` when GitHub refused to give
      it, or nil when it was not read yet.
    * `reported` is what collectors say, `%{name => :online | :busy |
      :offline}`.
    * `seen` is the names of your own runners that ran the repository's
      jobs lately.
    * `busy` is `%{name => job name}` for the jobs running now.

  `state` is `:online`, `:busy` or `:offline` (`:unknown` only for a
  status GitHub's list gives that the board does not know); `from` is
  `:github` or `:collector`.

  A collector does not know which repository its runner works for, so
  what it reports only gives a state to a runner the repository's jobs ran
  on; it adds no runner of its own. The rest of `seen` is `unreported/3`.
  """
  def states(listed, reported, seen, busy) do
    github = if is_list(listed), do: Map.new(listed, &{&1.name, github_state(&1)}), else: %{}

    names =
      (Map.keys(github) ++ Enum.filter(seen, &Map.has_key?(reported, &1)))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(names, fn name ->
      {state, from} =
        if Map.has_key?(github, name),
          do: {github[name], :github},
          else: {reported[name], :collector}

      %{name: name, state: state, job: if(state == :busy, do: busy[name]), from: from}
    end)
  end

  @doc """
  The runners in `seen` that neither GitHub's list nor a collector
  reports: `%{count, why}`, or nil when there are none. They are counted,
  not listed: their state is not known, and runners made for one job each
  leave a new name behind every time.
  """
  def unreported(listed, reported, seen) do
    known = MapSet.new(listed_names(listed) ++ Map.keys(reported))

    case seen |> Enum.uniq() |> Enum.reject(&MapSet.member?(known, &1)) do
      [] -> nil
      names -> %{count: length(names), why: why_unknown(listed)}
    end
  end

  defp github_state(%{status: "online", busy: true}), do: :busy
  defp github_state(%{status: "online"}), do: :online
  defp github_state(%{status: "offline"}), do: :offline
  defp github_state(_), do: :unknown

  defp why_unknown(:hidden),
    do: "Your GitHub login cannot list this repository's runners, and no collector reports them"

  defp why_unknown(list) when is_list(list),
    do:
      "GitHub's list for this repository does not have them (they may be gone, or belong to the organization), and no collector reports them"

  defp why_unknown(_), do: "Not read from GitHub yet, and no collector reports them"

  @doc "A one-line count, like \"2 online, 1 busy\"."
  def count_line(runners) do
    counts = Enum.frequencies_by(runners, & &1.state)

    [online: "online", busy: "busy", offline: "offline", unknown: "not known"]
    |> Enum.filter(fn {state, _} -> counts[state] end)
    |> Enum.map_join(", ", fn {state, word} -> "#{counts[state]} #{word}" end)
  end

  @doc "The word for a state, as the board shows it."
  def word(:busy), do: "busy"
  def word(:online), do: "online"
  def word(:offline), do: "offline"
  def word(_), do: "state not known"
end
