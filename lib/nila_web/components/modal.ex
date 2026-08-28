defmodule NilaWeb.Components.Modal do
  @moduledoc """
  Modal, sheet, and full-screen workbench components with shared dismissal
  behavior and show/hide JS commands.
  """
  use Phoenix.Component

  import NilaWeb.Components.Icon

  alias Phoenix.LiveView.JS

  @doc """
  Renders a centered modal over an ink scrim. `on_close` is the event fired by
  the close button, click-away, and Escape; the caller controls visibility (use
  `:if`). `width` and `scrim` expose the only supported visual choices.

  Set `variant="sheet"` for a focused task surface attached to a viewport edge.
  It keeps the ordinary dialog's modal semantics, focus wrapping, dismissal,
  and elevation while changing only its placement and geometry. `side` defaults
  to `"right"`; `return_focus` restores the invoking control after dismissal.

  Set `variant="workbench"` for a sustained, full-viewport review surface.
  Workbenches never close on click-away. Set `close_on_escape={false}` while an
  edit is active, and use `close_label="Done"` for an explicit exit affordance.

  Put dialog actions directly in `:footer`, secondary action first. The footer
  owns right alignment, spacing, and wrapping; callers do not need a layout wrapper.
  For forms in the body, associate submit buttons using the form's DOM `id`.

  ## Examples

      <.modal :if={@show_form} id="invoice-form-modal" title="Add Invoice" on_close="close-invoice-form">
        …form…
      </.modal>

      <.modal
        :if={@switching_client}
        id="client-switcher"
        title="Switch client"
        on_close="close-client-switcher"
        variant="sheet"
        side="right"
        return_focus="#open-client-switcher"
      >
        …client list…
      </.modal>

      <.modal
        :if={@reviewing}
        id="invoice-review"
        title="Review invoice"
        on_close="finish-review"
        variant="workbench"
        close_label="Done"
        close_on_escape={not @editing}
      >
        …review surface…
      </.modal>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_close, :string, required: true
  attr :variant, :string, values: ~w(modal sheet workbench), default: "modal"
  attr :side, :string, values: ~w(top right bottom left), default: "right"
  attr :return_focus, :string, default: nil
  attr :close_label, :string, default: nil
  attr :close_on_escape, :boolean, default: true
  attr :target, :any, default: nil
  attr :width, :string, default: "standard", values: ~w(standard wide extra-wide)
  attr :scrim, :string, default: "standard", values: ~w(standard document)
  slot :header
  slot :inner_block, required: true
  slot :footer

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class={["nila-modal-scrim", @variant == "modal" && "px-4"]}
      data-scrim={@scrim}
      data-variant={@variant}
      data-side={@variant == "sheet" && @side}
      phx-remove={return_focus(@return_focus)}
    >
      <.focus_wrap
        id={"#{@id}-focus-wrap"}
        phx-click-away={@variant in ~w(modal sheet) && @on_close}
        phx-window-keydown={@close_on_escape && @on_close}
        phx-key={@close_on_escape && "escape"}
        phx-target={@target}
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        class="nila-modal-panel"
        data-variant={@variant}
        data-width={@width}
        data-side={@variant == "sheet" && @side}
      >
        <header class="mb-block flex shrink-0 items-start justify-between gap-4">
          <%= if @header == [] do %>
            <h3 id={"#{@id}-title"} class="text-base-content text-body font-semibold">{@title}</h3>
          <% else %>
            <div class="min-w-0 flex-1">{render_slot(@header, "#{@id}-title")}</div>
          <% end %>
          <button
            type="button"
            phx-click={@on_close}
            phx-target={@target}
            aria-label={@close_label || "Close #{@title}"}
            class="nila-modal-close"
            data-label={not is_nil(@close_label)}
          >
            <span :if={@close_label}>{@close_label}</span>
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </header>
        <%!-- The body owns the scrolling, not the panel. A fixed-height modal or
              full-height workbench can hand `h-full` to its content, allowing
              panes to scroll independently instead of as one long page. --%>
        <div class="nila-modal-body min-h-0 flex-1 overflow-y-auto">
          {render_slot(@inner_block)}
        </div>
        <footer :if={@footer != []} class="nila-modal-footer">
          {render_slot(@footer)}
        </footer>
      </.focus_wrap>
    </div>
    """
  end

  defp return_focus(nil), do: nil
  defp return_focus(selector), do: JS.focus(to: selector)

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all duration-calm", "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 150,
      transition:
        {"transition-all duration-fast", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end
end
