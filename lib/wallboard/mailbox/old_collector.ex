defmodule Wallboard.Mailbox.OldCollector do
  @moduledoc """
  The mailbox item for a machine that still runs the upload hooks of
  VitalAIze 0.2.0 (see `Wallboard.OldCollectors`): its name, and what to
  do about it. One item for each machine. It goes when that machine pairs,
  or with Dismiss.
  """

  @behaviour Wallboard.Mailbox.Kind

  alias Wallboard.OldCollectors

  @impl true
  def items do
    for %{machine: machine} <- OldCollectors.waiting() do
      %{
        id: machine,
        title: "A machine still uses the old collector",
        body: [
          {:strong, machine},
          {:text, " still uses the old collector. Install the new one on it."}
        ],
        actions: [{"dismiss", "Dismiss"}]
      }
    end
  end

  @impl true
  def act(id, "dismiss"), do: OldCollectors.dismiss(id)
  def act(_id, _action), do: {:error, :gone}
end
