defmodule NilaWeb.Components.Menu do
  @moduledoc "Small anchored action menus with shared keyboard and dismissal behavior."

  use Phoenix.Component

  import NilaWeb.Components.Button
  import NilaWeb.Components.Icon

  attr :id, :string, required: true
  attr :label, :string, required: true

  slot :item, required: true do
    attr :id, :string, required: true
    attr :label, :string, required: true
    attr :icon, :string
    attr :tone, :string
    attr :on_click, :string, required: true
    attr :value, :string, required: true
  end

  def action_menu(assigns) do
    ~H"""
    <div id={@id} class="relative z-10 inline-flex">
      <.button
        id={"#{@id}-trigger"}
        type="button"
        variant="ghost"
        size="xs"
        popovertarget={"#{@id}-popover"}
        aria-label={@label}
        aria-haspopup="menu"
        title={@label}
      >
        <.icon name="hero-ellipsis-horizontal" class="size-4" />
      </.button>

      <div
        id={"#{@id}-popover"}
        popover="auto"
        role="menu"
        aria-label={@label}
        class="bg-base-100 border-base-300 rounded-box shadow-moon text-base-content invisible fixed inset-auto z-50 m-0 w-max min-w-40 border p-2"
        data-trigger={"#{@id}-trigger"}
        phx-hook=".ActionMenuPopover"
      >
        <button
          :for={item <- @item}
          type="button"
          id={item.id}
          role="menuitem"
          class="data-[tone=error]:hover:bg-error/10 data-[tone=error]:text-error focus-visible:outline-focus-8 hover:bg-base-200 hover:text-base-content rounded-field text-ink-muted text-ui flex h-9 w-full items-center gap-2 px-3 font-medium focus-visible:outline-2 focus-visible:-outline-offset-2"
          data-tone={item[:tone]}
          phx-click={item.on_click}
          phx-value-id={item.value}
          popovertarget={"#{@id}-popover"}
          popovertargetaction="hide"
        >
          <.icon :if={item[:icon]} name={item.icon} class="size-4" />
          <span>{item.label}</span>
        </button>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".ActionMenuPopover">
          export default {
            mounted() {
              this.trigger = document.getElementById(this.el.dataset.trigger)
              this.position = () => this.positionMenu()
              this.onToggle = event => {
                if (event.newState === "open") {
                  this.positionMenu()
                  this.el.style.visibility = "visible"
                } else {
                  this.el.style.visibility = "hidden"
                }
              }
              this.el.addEventListener("toggle", this.onToggle)
              window.addEventListener("resize", this.position)
              window.addEventListener("scroll", this.position, true)
            },
            destroyed() {
              this.el.removeEventListener("toggle", this.onToggle)
              window.removeEventListener("resize", this.position)
              window.removeEventListener("scroll", this.position, true)
            },
            positionMenu() {
              if (!this.trigger || !this.el.matches(":popover-open")) return

              const trigger = this.trigger.getBoundingClientRect()
              const gap = 4
              const edge = 8
              const width = this.el.offsetWidth
              const height = this.el.offsetHeight
              const left = Math.min(
                window.innerWidth - width - edge,
                Math.max(edge, trigger.right - width)
              )
              const below = trigger.bottom + gap
              const top = below + height <= window.innerHeight - edge
                ? below
                : Math.max(edge, trigger.top - height - gap)

              this.el.style.left = `${left}px`
              this.el.style.top = `${top}px`
            }
          }
        </script>
      </div>
    </div>
    """
  end
end
