defmodule Wallboard.MilestoneTitles do
  @moduledoc """
  The title of each milestone a live session's issue is in, for the line
  above the cards on the Agents tab (issue #144).

  A title is GitHub text, and VitalAIze is public: no issue text in logs,
  crash reports included. A crash report prints a process's state and the
  message it was handling, so the title is kept here, in a table, and
  nowhere else: not in the issue finder's facts or memory, not in what it
  broadcasts, and not in the board page's assigns. The page looks a title
  up only at the moment it draws the line. This process holds only the
  table's id.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Keeps the title of the milestone `number` in `repo` (`owner/name`)."
  def put(repo, number, title) when is_binary(title) do
    :ets.insert(@table, {{String.downcase(repo), number}, title})
    :ok
  rescue
    # Not started: nothing is drawn, so nothing needs keeping.
    ArgumentError -> :ok
  end

  @doc "The milestone's title, or nil when none is kept."
  def get(repo, number) do
    case :ets.lookup(@table, {String.downcase(repo), number}) do
      [{_, title}] -> title
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(nil) do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, table}
  end
end
