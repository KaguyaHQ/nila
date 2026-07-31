defmodule NilaWeb.Components.Fold do
  @moduledoc """
  A disclosure whose open state lives on the server.

  A plain `<details>` does not survive a LiveView patch: the browser sets `open`
  when the reader clicks, the next render doesn't carry it, and morphdom syncs
  it away — so confirming an issue, accepting a difference or a pile landing on
  the PubSub silently collapses every section the reader had opened. On a page
  that re-renders whenever anything arrives, that is the reader losing their
  place because something else moved.

  So the caller holds a set of open fold ids and passes `open`; the summary
  pushes `on_toggle` with `%{fold: id}`. The native toggle still runs first, so
  the fold opens instantly and the round trip only confirms it.

  One vocabulary throughout: a trailing chevron-down that rotates 180°. A
  leading chevron-right means a *row* expands in place, which is a different
  gesture and keeps its own mark.
  """
  use Phoenix.Component

  import NilaWeb.Components.Icon

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :open, :boolean, default: false
  attr :on_toggle, :string, default: "toggle-fold"
  attr :class, :any, default: nil
  attr :summary_class, :any, default: "text-ink-muted text-small"
  attr :rest, :global

  slot :summary, required: true
  slot :inner_block, required: true

  def fold(assigns) do
    ~H"""
    <details id={@id} open={@open} class={["group/fold scroll-mt-28", @class]} {@rest}>
      <summary
        class={[
          "hover:text-ink flex cursor-pointer list-none items-center gap-2",
          @summary_class
        ]}
        phx-click={JS.push(@on_toggle, value: %{fold: @id})}
      >
        {render_slot(@summary)}
        <.icon
          name="hero-chevron-down-mini"
          class="fold-chevron text-ink-faint size-4 shrink-0 transition-transform"
        />
      </summary>
      {render_slot(@inner_block)}
    </details>
    """
  end
end
