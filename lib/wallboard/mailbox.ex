defmodule Wallboard.Mailbox do
  @moduledoc """
  The mailbox: the envelope in the board's header, and the list of things
  the board asks its owner to decide.

  It holds administrative decisions only: a device that wants to open the
  board, a new machine that wants to connect, a repo to track, and later a
  new version to install. It never holds anything about an agent waiting
  on its person. Those stay the "Needs you" banner and the session cards.

  An item goes away once someone acts on it. Nothing here is saved: each
  kind of item keeps its own state and the mailbox asks it.

  ## Adding a kind of item

  Write a module with `Wallboard.Mailbox.Kind`'s two functions and add it
  to `@kinds`. That is the whole change: the count, the list and the
  buttons follow.

  An item is a map:

    * `id`: text that names it among its own kind's items
    * `title`: one short line
    * `body`: what to decide, as a list of pieces, each `{:text, text}`,
      `{:code, text}` (shown in fixed-width type) or `{:strong, text}`
    * `actions`: `[{key, label}]`; the first is the one the mailbox leads with

  Whoever shows the mailbox decides who may act (see
  `WallboardWeb.Auth.may_decide?/1`). `act/2` itself asks no questions.
  """

  defmodule Kind do
    @moduledoc "What a kind of mailbox item provides (see `Wallboard.Mailbox`)."

    @doc "The items of this kind waiting now, oldest first."
    @callback items() :: [map()]

    @doc """
    Does `action` (one of the item's own action keys) to the item `id`.
    `:ok`, or `{:error, reason}`: `:gone` when the item is no longer there.
    """
    @callback act(id :: String.t(), action :: String.t()) :: :ok | {:error, term()}
  end

  # Every kind of item, in the order the mailbox lists them.
  @kinds [
    {"device", Wallboard.Mailbox.NewDevice},
    {"machine", Wallboard.Mailbox.NewMachine},
    {"repo", Wallboard.Mailbox.NewRepo}
  ]

  @topic "mailbox"

  @doc "The PubSub topic that hears `{:mailbox, :changed}` when the list changes."
  def topic, do: @topic

  @doc "Tells every open board the list changed."
  def changed, do: Phoenix.PubSub.broadcast(Wallboard.PubSub, @topic, {:mailbox, :changed})

  @doc "Every item waiting now. Each `id` is one `act/2` takes."
  def items do
    for {prefix, kind} <- @kinds, item <- kind_items(kind) do
      %{item | id: prefix <> ":" <> item.id}
    end
  end

  @doc "Acts on an item by its `id` from `items/0`."
  def act(id, action) when is_binary(id) and is_binary(action) do
    with [prefix, rest] <- String.split(id, ":", parts: 2),
         {_, kind} <- List.keyfind(@kinds, prefix, 0) do
      kind.act(rest, action)
    else
      _ -> {:error, :gone}
    end
  end

  def act(_, _), do: {:error, :gone}

  # One kind that fails must not empty the whole mailbox.
  defp kind_items(kind) do
    kind.items()
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end
