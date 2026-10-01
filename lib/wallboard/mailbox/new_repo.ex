defmodule Wallboard.Mailbox.NewRepo do
  @moduledoc """
  The mailbox item for agent work in a GitHub repository the Git tab does
  not follow (see `Wallboard.RepoPrompts`): the repository, the machines
  the work is on, Track and Ignore. A repository the hub's GitHub login
  cannot see says so and offers only Ignore.
  """

  @behaviour Wallboard.Mailbox.Kind

  alias Wallboard.RepoPrompts

  @impl true
  def items do
    for ask <- RepoPrompts.pending() do
      where = [{:text, "Someone is working in "}, {:strong, ask.repo}, {:text, on(ask.machines)}]

      if ask.visible? do
        %{
          id: ask.id,
          title: "Track a new repo?",
          body: where ++ [{:text, " The Git tab doesn't track it yet."}],
          actions: [{"track", "Track"}, {"ignore", "Ignore"}]
        }
      else
        %{
          id: ask.id,
          title: "Work in a repo the Git tab can't show",
          body:
            where ++
              [
                {:text,
                 " This hub's GitHub login can't see that repo, so the Git tab can't track it."}
              ],
          actions: [{"ignore", "Ignore"}]
        }
      end
    end
  end

  @impl true
  def act(id, "track"), do: RepoPrompts.track(id)
  def act(id, "ignore"), do: RepoPrompts.ignore(id)
  def act(_id, _action), do: {:error, :gone}

  defp on([]), do: "."
  defp on([one]), do: " on #{one}."
  defp on([one, two]), do: " on #{one} and #{two}."
  defp on([one | rest]), do: " on #{one} and #{length(rest)} other machines."
end
