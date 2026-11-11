defmodule Wallboard.Linear do
  @moduledoc """
  Reads Linear through its GraphQL API, for the issue each live session is
  on and how far down its milestone or project is (see
  `Wallboard.Sources.SessionIssues`).

  It is on once a Linear API key is set (`Wallboard.Secrets`), and reads
  nothing without one. It only reads: the queries here are every question
  it ever asks, and none of them changes anything in Linear.

  What comes back is cut down here to ids, numbers and names: an issue's
  own id (`VIT-41`), the ids of its project and milestone, and each
  issue's kind of status when a milestone is counted. An issue's title or
  text is never asked for. A milestone's and a project's names are Linear
  text, so the caller hands them to `Wallboard.MilestoneTitles` and keeps
  them nowhere else.
  """

  alias Wallboard.{IssueRef, Secrets}

  @url ~c"https://api.linear.app/graphql"

  # How long one call may take.
  @read_ms 20_000

  # A milestone or project is counted 250 issues to a call, and at most
  # this many calls: one with more issues than that shows no count.
  @pages 4

  @issue "identifier project { id } projectMilestone { id }"

  @doc "Whether a Linear key is set, so Linear can be asked."
  def on?, do: match?({:ok, _}, Secrets.linear())

  @doc """
  The letters of every team in the workspace, as a `MapSet`, so a word
  written like an issue of no team here (`UTF-8`) is never asked about.
  `{:ok, set}` or `:failed`.
  """
  def teams do
    with {:ok, %{"teams" => %{"nodes" => nodes}}} when is_list(nodes) <-
           ask("query { teams(first: 250) { nodes { key } } }", %{}) do
      {:ok, for(%{"key" => key} <- nodes, IssueRef.team?(key), into: MapSet.new(), do: key)}
    else
      _ -> :failed
    end
  end

  @doc """
  Each named issue, `{team, number}`, as `{id or false, place}`: its id as
  Linear writes it, or false when the team has no such issue, and the
  milestone or project it is in (`{:milestone, id}`, `{:project, id}` or
  nil). One call for them all. `{:ok, %{{team, number} => answer}}` or
  `:failed`.
  """
  def issues(pairs) do
    pairs = Enum.with_index(pairs)

    query = """
    query(#{Enum.map_join(pairs, ", ", fn {_, i} -> "$t#{i}: String!, $n#{i}: Float!" end)}) {
      #{Enum.map_join(pairs, "\n", fn {_, i} -> "i#{i}: issues(filter: {team: {key: {eq: $t#{i}}}, number: {eq: $n#{i}}}, first: 1) { nodes { #{@issue} } }" end)}
    }
    """

    vars = for {{team, n}, i} <- pairs, kv <- [{"t#{i}", team}, {"n#{i}", n}], into: %{}, do: kv

    case ask(query, vars) do
      {:ok, got} ->
        {:ok,
         for {pair, i} <- pairs, into: %{} do
           case got["i#{i}"] do
             %{"nodes" => [issue | _]} -> {pair, issue(issue) || {false, nil}}
             _ -> {pair, {false, nil}}
           end
         end}

      :failed ->
        :failed
    end
  end

  @doc """
  The issue Linear ties to each branch name, as `{id or nil, place}`, as
  `issues/1` gives them. One call for them all. `{:ok, %{branch =>
  answer}}` or `:failed`.
  """
  def branches(names) do
    names = Enum.with_index(names)

    query = """
    query(#{Enum.map_join(names, ", ", fn {_, i} -> "$b#{i}: String!" end)}) {
      #{Enum.map_join(names, "\n", fn {_, i} -> "b#{i}: issueVcsBranchSearch(branchName: $b#{i}) { #{@issue} }" end)}
    }
    """

    vars = for {name, i} <- names, into: %{}, do: {"b#{i}", name}

    case ask(query, vars) do
      {:ok, got} ->
        {:ok, for({name, i} <- names, into: %{}, do: {name, issue(got["b#{i}"]) || {nil, nil}})}

      :failed ->
        :failed
    end
  end

  @doc """
  How far down a milestone (`:milestone`) or a whole project (`:project`)
  is: `{:ok, %{done, total, title, project}}`, counting its issues that
  are not canceled, and as done those Linear calls completed. `title` is
  the milestone's or the project's name and `project` the name of a
  milestone's project (nil for a project). `{:ok, nil}` when it has more
  issues than are counted, and `:failed` when Linear could not say.
  """
  def counts(kind, id) when kind in [:milestone, :project], do: count(kind, id, nil, 0, 0, nil, 1)

  defp count(kind, id, after_, done, total, names, page) do
    {named, field} =
      case kind do
        :milestone ->
          {"named: projectMilestone(id: $id) { name project { name } }", "projectMilestone"}

        :project ->
          {"named: project(id: $id) { name }", "project"}
      end

    # The names are asked for once, with the first 250.
    {vars, named, sent} =
      if page == 1,
        do: {"$id: String!, $fid: ID!, $after: String", named, ["id", "fid", "after"]},
        else: {"$fid: ID!, $after: String", "", ["fid", "after"]}

    asked = Map.take(%{"id" => id, "fid" => id, "after" => after_}, sent)

    query = """
    query(#{vars}) {
      #{named}
      issues(filter: {#{field}: {id: {eq: $fid}}, state: {type: {nin: ["canceled", "duplicate"]}}}, first: 250, after: $after) {
        nodes { state { type } }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    with {:ok, %{"issues" => %{"nodes" => nodes, "pageInfo" => info}} = got} when is_list(nodes) <-
           ask(query, asked),
         names when not is_nil(names) <- names || names(got["named"]) do
      done = done + Enum.count(nodes, &(get_in(&1, ["state", "type"]) == "completed"))
      total = total + length(nodes)

      case info do
        %{"hasNextPage" => true, "endCursor" => cursor} when is_binary(cursor) ->
          if page < @pages,
            do: count(kind, id, cursor, done, total, names, page + 1),
            else: {:ok, nil}

        _ ->
          {:ok, Map.merge(names, %{done: done, total: total})}
      end
    else
      _ -> :failed
    end
  end

  defp names(%{"name" => title} = named) when is_binary(title) do
    case named["project"] do
      %{"name" => project} when is_binary(project) -> %{title: title, project: project}
      _ -> %{title: title, project: nil}
    end
  end

  defp names(_), do: nil

  # An issue as Linear answers it, cut down to its id and where it is. Nil
  # when the answer is not an issue.
  defp issue(%{"identifier" => id} = issue) when is_binary(id) do
    if id =~ ~r/\A[A-Z][A-Z0-9]{0,9}-\d{1,9}\z/ do
      place =
        case {id(issue["projectMilestone"]), id(issue["project"])} do
          {m, _} when is_binary(m) -> {:milestone, m}
          {_, p} when is_binary(p) -> {:project, p}
          _ -> nil
        end

      {id, place}
    end
  end

  defp issue(_), do: nil

  # Linear's own id of a thing: letters, digits and dashes only.
  defp id(%{"id" => id}) when is_binary(id),
    do: if(id =~ ~r/\A[0-9a-fA-F-]{8,64}\z/, do: id)

  defp id(_), do: nil

  # One question to Linear: `{:ok, data}` or `:failed`. Why it failed is
  # not kept: an error from Linear can repeat what was asked.
  defp ask(query, vars) do
    with {:ok, key_fun} <- Secrets.linear(),
         {:ok, body} <- post().(query, vars, key_fun),
         {:ok, %{"data" => %{} = data} = answer} <- Jason.decode(body),
         true <- answer["errors"] in [nil, []] do
      {:ok, data}
    else
      _ -> :failed
    end
  end

  # A test puts its own stand-in for Linear here.
  defp post, do: Application.get_env(:wallboard, :linear_post, &post/3)

  defp post(query, vars, key_fun) do
    body = Jason.encode!(%{query: query, variables: vars})
    headers = [{~c"authorization", String.to_charlist(key_fun.())}]

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(
           :post,
           {@url, headers, ~c"application/json", body},
           [timeout: @read_ms, ssl: ssl],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, resp}} -> {:ok, resp}
      _ -> :failed
    end
  end
end
