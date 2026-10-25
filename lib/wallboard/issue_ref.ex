defmodule Wallboard.IssueRef do
  @moduledoc """
  The issue a prompt names, written the way people write one (issue #143):

    * `#1418`
    * `issue 1418` or `issue #1418`, in any capitals
    * a link to the issue, `https://github.com/acme/shop/issues/1418`
    * a project-board link that opens it, `...?pane=issue&issue=acme%7Cshop%7C1418`

  A link names its repository; the other forms mean the session's own. When
  a prompt names more than one, the first in it wins. Only the repository
  and the number are kept, never the prompt's text.
  """

  @forms [
    {:link, ~r"https?://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/(\d{1,9})(?!\w)"},
    {:link, ~r"[?&]issue=([A-Za-z0-9_.-]+)(?:%7C|\|)([A-Za-z0-9_.-]+)(?:%7C|\|)(\d{1,9})(?!\w)"i},
    {:bare, ~r"(?<![\w#&])#(\d{1,9})(?!\w)"},
    {:bare, ~r"(?<!\w)issue\s+#?(\d{1,9})(?!\w)"i}
  ]

  @doc "The first issue the text names, as `%{repo, number}` (repo nil for the session's own), or nil."
  def find(text) when is_binary(text) do
    @forms
    |> Enum.flat_map(fn {kind, re} ->
      case Regex.run(re, text, return: :index) do
        [{at, _} | groups] ->
          [{at, kind, Enum.map(groups, &binary_part(text, elem(&1, 0), elem(&1, 1)))}]

        nil ->
          []
      end
    end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
    |> case do
      {_, :link, [owner, name, n]} -> %{repo: owner <> "/" <> name, number: String.to_integer(n)}
      {_, :bare, [n]} -> %{repo: nil, number: String.to_integer(n)}
      nil -> nil
    end
  end

  def find(_), do: nil
end
