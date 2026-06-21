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
  `:if`). `class` sets the panel width (defaults to `max-w-lg`).

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
    <div id={@id} class="fixed inset-0 z-50 flex items-center justify-center bg-base-content/40 px-4">
      <.focus_wrap
        id={"#{@id}-focus-wrap"}
        phx-click-away={@on_close}
        phx-window-keydown={@on_close}
        phx-key="escape"
        class={[
          "max-h-[90vh] w-full overflow-y-auto rounded-box border border-base-300 bg-base-100 p-5 shadow-moon-lg",
          @class
        ]}
      >
        <header class="mb-4 flex items-center justify-between">
          <h3 class="text-body font-semibold text-base-content">{@title}</h3>
          <button
            type="button"
            phx-click={@on_close}
            class="rounded-field p-1 text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </header>
        {render_slot(@inner_block)}
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
