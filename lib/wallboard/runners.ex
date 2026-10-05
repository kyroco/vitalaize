defmodule Wallboard.Runners do
  @moduledoc """
  Which machine ran a GitHub Actions job, one of GitHub's or one of your own
  (a self-hosted runner), and the state of each of your own runners.

  A job's runner group says it: GitHub's own machines are in the group
  "GitHub Actions". A job with the "self-hosted" label, or in any other
  group, ran on your own machine. Jobs saved before the board kept the group
  have only the runner's name, and GitHub names its own machines like
  "GitHub Actions 1000041223". Anything else is not known, and is never
  guessed.

  A runner's state comes from GitHub's list of the repository's runners when
  the board's GitHub login may read it (that needs admin rights on the
  repository), else from a collector on the runner's machine. When neither
  says, the state is not known, and the board says why.

  Nothing here, or anywhere in the board, installs, starts, stops or changes
  a runner: it only reads.
  """

  @github_group "GitHub Actions"

  @doc """
  Whose machine ran a job: `:github`, `:own` or `:unknown`. `job` is a map
  with any of `runner_group_name`, `labels` (a list, or the saved text with
  commas) and `runner_name`, under string or atom keys.
  """
  def kind(job) do
    group = field(job, :runner_group_name)
    name = field(job, :runner_name)

    cond do
      group == @github_group -> :github
      "self-hosted" in labels(field(job, :labels)) -> :own
      is_binary(group) and group != "" -> :own
      is_binary(name) and Regex.match?(~r/\AGitHub Actions \d+\z/, name) -> :github
      true -> :unknown
    end
  end

  defp field(job, key), do: Map.get(job, key) || Map.get(job, Atom.to_string(key))

  defp labels(list) when is_list(list), do: list
  defp labels(text) when is_binary(text), do: String.split(text, ",", trim: true)
  defp labels(_), do: []

  @doc """
  The names of your own runners that ran, or run, any of `jobs`, in the
  order they first appear.
  """
  def own_names(jobs) do
    jobs
    |> Enum.filter(&(kind(&1) == :own))
    |> Enum.map(&field(&1, :runner_name))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  @doc """
  Each of a repository's own runners with its state, sorted by name:
  `%{name, state, job, from, why}`.

    * `listed` is GitHub's list of the repository's runners
      (`%{name, status, busy}` each), `:hidden` when GitHub refused to give
      it, or nil when it was not read yet.
    * `reported` is what collectors say, `%{name => :online | :busy |
      :offline}`.
    * `seen` is the names of your own runners that ran the repository's
      jobs lately.
    * `busy` is `%{name => job name}` for the jobs running now.

  `state` is `:online`, `:busy`, `:offline` or `:unknown`; `from` is
  `:github`, `:collector` or nil; `why` says, for an unknown state, why it
  is not known.
  """
  def states(listed, reported, seen, busy) do
    github = if is_list(listed), do: Map.new(listed, &{&1.name, github_state(&1)}), else: %{}

    names =
      (Map.keys(github) ++ Map.keys(reported) ++ seen)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(names, fn name ->
      {state, from} =
        cond do
          Map.has_key?(github, name) -> {github[name], :github}
          Map.has_key?(reported, name) -> {reported[name], :collector}
          true -> {:unknown, nil}
        end

      %{
        name: name,
        state: state,
        job: if(state == :busy, do: busy[name]),
        from: from,
        why: if(state == :unknown, do: why_unknown(listed))
      }
    end)
  end

  defp github_state(%{status: "online", busy: true}), do: :busy
  defp github_state(%{status: "online"}), do: :online
  defp github_state(%{status: "offline"}), do: :offline
  defp github_state(_), do: :unknown

  defp why_unknown(:hidden),
    do:
      "Your GitHub login cannot list this repository's runners, and no collector on that machine reports it"

  defp why_unknown(list) when is_list(list),
    do:
      "GitHub's list for this repository does not have it (it may belong to the organization), and no collector on that machine reports it"

  defp why_unknown(_), do: "Not read from GitHub yet, and no collector on that machine reports it"

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
