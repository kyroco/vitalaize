defmodule Wallboard.Mailbox.NewDevice do
  @moduledoc """
  The mailbox item for a browser that asks to open the board (see
  `Wallboard.Devices`): what it is, where it is, the code it shows, Approve
  and Refuse.
  """

  @behaviour Wallboard.Mailbox.Kind

  alias Wallboard.Devices

  @impl true
  def items do
    for r <- Devices.pending() do
      %{
        id: r.id,
        title: "A device wants to open the board",
        body: [
          {:text, "#{r.name} at #{r.address} shows the code "},
          {:code, r.code},
          {:text,
           ". Approve only if that matches what the device shows. It can then change settings and approve others."}
        ],
        actions: [{"approve", "Approve"}, {"refuse", "Refuse"}]
      }
    end
  end

  @impl true
  def act(id, "approve"), do: Devices.approve(id)
  def act(id, "refuse"), do: Devices.refuse(id)
  def act(_id, _action), do: {:error, :gone}
end
