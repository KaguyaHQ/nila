defmodule NilaWeb.Components.Modal do
  @moduledoc """
  Centered modal component and the shared show/hide JS commands.
  """
  use Phoenix.Component

  import NilaWeb.Components.Icon

  alias Phoenix.LiveView.JS

  @doc """
  Renders a centered modal over an ink scrim. `on_close` is the `phx-click`
  event fired by the header close button; the caller controls visibility (use
  `:if`). `class` sets the panel width (defaults to `max-w-lg`) and may also set
  a height (`h-[90vh]`) when the content wants to fill the panel and manage its
  own scrolling.

  ## Examples

      <.modal :if={@show_form} id="invoice-form-modal" title="Add Invoice" on_close="close-invoice-form">
        …form…
      </.modal>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_close, :string, required: true
  attr :class, :any, default: "max-w-lg"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div id={@id} class="bg-base-content/40 fixed inset-0 z-50 flex items-center justify-center px-4">
      <.focus_wrap
        id={"#{@id}-focus-wrap"}
        phx-click-away={@on_close}
        phx-window-keydown={@on_close}
        phx-key="escape"
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        class={[
          "bg-base-100 border-base-300 rounded-box shadow-moon-lg flex max-h-[90vh] w-full flex-col border p-5",
          @class
        ]}
      >
        <header class="mb-4 flex shrink-0 items-center justify-between">
          <h3 id={"#{@id}-title"} class="text-base-content text-body font-semibold">{@title}</h3>
          <button
            type="button"
            phx-click={@on_close}
            class="hover:bg-base-200 hover:text-base-content rounded-field text-base-content/60 p-1 transition"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </header>
        <%!-- The body owns the scrolling, not the panel: a modal given a height
              (`class="h-[90vh]"`) can then hand `h-full` to its content, so an
              inspection surface can scroll its two halves independently instead
              of scrolling as one long page. --%>
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
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end
end
