defmodule NilaWeb.Components.Modal do
  @moduledoc """
  Modal and full-screen workbench components with shared show/hide JS commands.
  """
  use Phoenix.Component

  import NilaWeb.Components.Icon

  alias Phoenix.LiveView.JS

  @doc """
  Renders a centered modal over an ink scrim. `on_close` is the event fired by
  the close button, click-away, and Escape; the caller controls visibility (use
  `:if`). `width` and `scrim` expose the only supported visual choices.

  Set `variant="workbench"` for a sustained, full-viewport review surface.
  Workbenches never close on click-away. Set `close_on_escape={false}` while an
  edit is active, and use `close_label="Done"` for an explicit exit affordance.

  ## Examples

      <.modal :if={@show_form} id="invoice-form-modal" title="Add Invoice" on_close="close-invoice-form">
        …form…
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
  attr :variant, :string, values: ~w(modal workbench), default: "modal"
  attr :close_label, :string, default: nil
  attr :close_on_escape, :boolean, default: true
  attr :target, :any, default: nil
  attr :width, :string, default: "standard", values: ~w(standard wide extra-wide)
  attr :scrim, :string, default: "standard", values: ~w(standard document)
  slot :header
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class={["nila-modal-scrim", @variant == "modal" && "px-4"]}
      data-scrim={@scrim}
    >
      <.focus_wrap
        id={"#{@id}-focus-wrap"}
        phx-click-away={@variant == "modal" && @on_close}
        phx-window-keydown={@close_on_escape && @on_close}
        phx-key={@close_on_escape && "escape"}
        phx-target={@target}
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        class="nila-modal-panel"
        data-variant={@variant}
        data-width={@width}
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
        <div class="min-h-0 flex-1 overflow-y-auto">{render_slot(@inner_block)}</div>
      </.focus_wrap>
    </div>
    """
  end

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
