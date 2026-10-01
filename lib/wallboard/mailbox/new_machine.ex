defmodule Wallboard.Mailbox.NewMachine do
  @moduledoc """
  The mailbox item for a machine that asks to connect (see
  `Wallboard.Pairing`): its name, the code it shows, Approve and Refuse.
  """

  @behaviour Wallboard.Mailbox.Kind

  alias Wallboard.Pairing.Door

  @impl true
  def items do
    for r <- Door.pending() do
      %{
        id: r.id,
        title: "A new machine wants to connect",
        body:
          [
            {:text, "#{r.name} shows the code "},
            {:code, r.code},
            {:text, ". Approve only if that matches what the machine shows."}
          ] ++
            if(r.replaces?,
              do: [
                {:text,
                 " A machine named #{r.name} is connected already; approving this one disconnects it."}
              ],
              else: []
            ),
        actions: [{"approve", "Approve"}, {"refuse", "Refuse"}]
      }
    end
  end

  @impl true
  def act(id, "approve"), do: Door.approve(id)
  def act(id, "refuse"), do: Door.refuse(id)
  def act(_id, _action), do: {:error, :gone}
end
