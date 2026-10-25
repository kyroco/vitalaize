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

  A session keeps the first few it names, in order (`keep/2`): something
  written like one that is not an issue, such as the colour `#333333`, must
  not stop a later real one from counting. Which is an issue is for GitHub
  to say (see `Wallboard.Sources.SessionIssues`).
  """

  # How many a session keeps.
  @kept 3

  @forms [
    {:link, ~r"https?://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/(\d{1,9})(?!\w)"},
    {:link, ~r"[?&]issue=([A-Za-z0-9_.-]+)(?:%7C|\|)([A-Za-z0-9_.-]+)(?:%7C|\|)(\d{1,9})(?!\w)"i},
    {:bare, ~r"(?<![\w#&])#(\d{1,9})(?!\w)"},
    {:bare, ~r"(?<!\w)issue\s+#?(\d{1,9})(?!\w)"i}
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

  @doc "What a session keeps after one more prompt: the first #{@kept} it has named, in order."
  def keep(kept, _text) when length(kept) >= @kept, do: kept
  def keep(kept, text), do: (kept ++ find_all(text)) |> Enum.uniq() |> Enum.take(@kept)

  @doc "Whether a session has kept all it keeps."
  def full?(kept), do: length(kept) >= @kept

  defp ref(:link, [owner, name, n]),
    do: %{repo: owner <> "/" <> name, number: String.to_integer(n)}

  defp ref(:bare, [n]), do: %{repo: nil, number: String.to_integer(n)}
end
