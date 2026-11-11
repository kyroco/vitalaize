defmodule Wallboard.IssueRef do
  @moduledoc """
  The issues a prompt names, written the way people write one (issue #143):

    * `#1418`
    * `issue 1418` or `issue #1418`, in any capitals
    * a link to the issue, `https://github.com/acme/shop/issues/1418`
    * a project-board link that opens it, `...?pane=issue&issue=acme%7Cshop%7C1418`

  A link names its repository; the other forms mean the session's own.
  Number 0 is never an issue. Only the repository and the number are kept,
  never the prompt's text.

  A Linear issue is named by its own id, a team's letters and a number:

    * `VIT-41`, in capitals as Linear writes it
    * a link to the issue, `https://linear.app/acme/issue/VIT-41/some-title`

  It is kept as `%{team: "VIT", number: 41}`, with no repository.

  A session keeps the first few it names of each kind, in order
  (`keep/2`): something written like one that is not an issue, such as the
  colour `#333333` or the word `UTF-8`, must not stop a later real one
  from counting. Which is an issue is for GitHub or Linear to say (see
  `Wallboard.Sources.SessionIssues`).

  Many plain words are written like a Linear id (`UTF-8`, `ISO-8601`,
  `SHA-256`), so more of that kind are kept: which of them name a team in
  the workspace is only known where Linear is asked, and the first three
  that do are the ones that count there.
  """

  # How many GitHub references a session keeps.
  @kept 3

  # How many written like a Linear id it keeps.
  @kept_linear 12

  # A Linear team's letters: capitals and digits, a capital first.
  @team "[A-Z][A-Z0-9]{0,9}"

  @forms [
    {:link, ~r"https?://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/(\d{1,9})(?!\w)"},
    {:link, ~r"[?&]issue=([A-Za-z0-9_.-]+)(?:%7C|\|)([A-Za-z0-9_.-]+)(?:%7C|\|)(\d{1,9})(?!\w)"i},
    {:bare, ~r"(?<![\w#&])#(\d{1,9})(?!\w)"},
    {:bare, ~r"(?<!\w)issue\s+#?(\d{1,9})(?!\w)"i},
    {:linear, ~r"https?://linear\.app/[A-Za-z0-9_.-]+/issue/(#{@team})-(\d{1,9})(?!\w)"},
    # Not inside a link or a longer name: a link is the form above.
    {:linear, ~r"(?<![\w/.#-])(#{@team})-(\d{1,9})(?![\w-])"}
  ]

  @doc "The first issue the text names, as `%{repo, number}` (repo nil for the session's own), or nil."
  def find(text), do: text |> find_all() |> List.first()

  @doc "Every issue the text names, in the order written, each once."
  def find_all(text) when is_binary(text) do
    @forms
    |> Enum.flat_map(fn {kind, re} ->
      for [{at, _} | groups] <- Regex.scan(re, text, return: :index),
          do: {at, ref(kind, Enum.map(groups, &binary_part(text, elem(&1, 0), elem(&1, 1))))}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> Enum.reject(&(&1.number == 0))
    |> Enum.uniq()
  end

  def find_all(_), do: []

  @doc """
  What a session keeps after one more prompt, in the order written: the
  first #{@kept} GitHub references it has named, and the first
  #{@kept_linear} written like a Linear id.
  """
  def keep(kept, text) do
    if full?(kept) do
      kept
    else
      (kept ++ find_all(text))
      |> Enum.uniq()
      |> Enum.reduce({[], %{}}, fn ref, {out, seen} ->
        {kind, most} = if linear?(ref), do: {:linear, @kept_linear}, else: {:github, @kept}

        if Map.get(seen, kind, 0) < most,
          do: {[ref | out], Map.update(seen, kind, 1, &(&1 + 1))},
          else: {out, seen}
      end)
      |> elem(0)
      |> Enum.reverse()
    end
  end

  @doc "Whether a session has kept all it keeps, of both kinds."
  def full?(kept) do
    {linear, github} = Enum.split_with(kept, &linear?/1)
    length(linear) >= @kept_linear and length(github) >= @kept
  end

  @doc "How many written like a Linear id a session keeps."
  def kept_linear, do: @kept_linear

  @doc "Whether the reference names a Linear issue."
  def linear?(ref), do: is_map(ref) and is_binary(ref[:team])

  @doc "Whether the text is a Linear team's letters, as `VIT` in `VIT-41`."
  def team?(team), do: is_binary(team) and team =~ ~r/\A#{@team}\z/

  defp ref(:link, [owner, name, n]),
    do: %{repo: owner <> "/" <> name, number: String.to_integer(n)}

  defp ref(:bare, [n]), do: %{repo: nil, number: String.to_integer(n)}
  defp ref(:linear, [team, n]), do: %{team: team, number: String.to_integer(n)}
end
