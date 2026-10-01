defmodule WallboardWeb.MailboxPanel do
  @moduledoc """
  The open mailbox: the list of administrative decisions the board asks its
  owner for (see `Wallboard.Mailbox`), drawn over the board.
  """
  use WallboardWeb, :html

  attr :items, :list, required: true
  attr :note, :string, default: nil
  attr :may_decide?, :boolean, required: true
  attr :cannot, :string, required: true

  @doc """
  The open mailbox, over the board. Each kind of item brings its own words
  and buttons; without the right to decide, the buttons are there but off.
  """
  def panel(assigns) do
    ~H"""
    <div class="mailbox-scrim" phx-click="mailbox_close">
      <div class="mailbox-panel" role="dialog" aria-label="Mailbox" phx-click="noop">
        <div class="mailbox-head">
          <b>Mailbox</b>
          <span class="mailbox-sub">{mailbox_count(@items)}</span>
          <span class="grow"></span>
          <button class="close" phx-click="mailbox_close" aria-label="Close">×</button>
        </div>
        <p :if={@note} class="mailbox-note">{@note}</p>
        <p :if={@items != [] and not @may_decide? and !@note} class="mailbox-note">{@cannot}</p>
        <div :for={item <- @items} class="mailbox-item">
          <div class="mailbox-title">{item.title}</div>
          <div class="mailbox-body">{pieces(item.body)}</div>
          <div class="mailbox-actions">
            <button
              :for={{{key, label}, i} <- Enum.with_index(item.actions)}
              class={["mailbox-act", i == 0 && "primary"]}
              phx-click="mailbox_act"
              phx-value-id={item.id}
              phx-value-action={key}
              disabled={not @may_decide?}
            >
              {label}
            </button>
          </div>
        </div>
        <p :if={@items == []} class="mailbox-empty">Nothing to decide.</p>
      </div>
    </div>
    """
  end

  # An item's words, joined with nothing between them, so a full stop sits
  # right after a code. Every piece is escaped.
  defp pieces(body) do
    for piece <- body do
      case piece do
        {:code, text} -> [~s(<span class="mailbox-code">), escape(text), "</span>"]
        {:strong, text} -> ["<b>", escape(text), "</b>"]
        {_, text} -> escape(text)
      end
    end
    |> raw()
  end

  defp escape(text), do: text |> to_string() |> html_escape() |> safe_to_string()

  defp mailbox_count([]), do: "nothing waiting"
  defp mailbox_count([_]), do: "1 thing to decide"
  defp mailbox_count(items), do: "#{length(items)} things to decide"
end
