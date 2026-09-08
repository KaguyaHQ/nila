defmodule NilaWeb.Components.Menu do
  @moduledoc "Small anchored action menus with shared keyboard and dismissal behavior."

  use Phoenix.Component

  import NilaWeb.Components.Button
  import NilaWeb.Components.Icon

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :trigger_label, :string, default: nil

  slot :item, required: true do
    attr :id, :string, required: true
    attr :label, :string, required: true
    attr :icon, :string
    attr :tone, :string
    attr :on_click, :any
    attr :value, :string
    attr :target, :any
    attr :form, :string
    attr :name, :string
  end

  def action_menu(assigns) do
    ~H"""
    <div id={@id} class="nila-action-menu relative z-10 inline-flex">
      <.button
        id={"#{@id}-trigger"}
        type="button"
        variant="ghost"
        size={if @trigger_label, do: "sm", else: "xs"}
        popovertarget={"#{@id}-popover"}
        aria-label={@label}
        aria-haspopup="menu"
        aria-expanded="false"
        title={@label}
      >
        <%= if @trigger_label do %>
          {@trigger_label} <.icon name="hero-chevron-down-mini" class="size-4" />
        <% else %>
          <.icon name="hero-ellipsis-horizontal" class="size-4" />
        <% end %>
      </.button>

      <div
        id={"#{@id}-popover"}
        popover="auto"
        role="menu"
        aria-label={@label}
        class="bg-panel-surface border-rule nila-action-menu-popover rounded-box shadow-moon text-base-content border p-2"
        data-trigger={"#{@id}-trigger"}
        phx-hook=".ActionMenuPopover"
      >
        <button
          :for={item <- @item}
          type={if item[:form], do: "submit", else: "button"}
          form={item[:form]}
          name={item[:name]}
          value={item[:form] && item[:value]}
          id={item.id}
          role="menuitem"
          class="data-[tone=error]:hover:bg-error/10 data-[tone=error]:text-error focus-visible:outline-focus hover:bg-interactive hover:text-base-content rounded-field text-ink-muted text-ui flex min-h-9 w-full items-center gap-2 px-3 font-medium focus-visible:outline-2 focus-visible:-outline-offset-2"
          data-tone={item[:tone]}
          phx-click={item[:on_click]}
          phx-value-id={!item[:form] && item[:value]}
          phx-target={item[:target]}
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
              this.onToggle = event => {
                this.trigger?.setAttribute("aria-expanded", String(event.newState === "open"))
                if (event.newState === "open") {
                  const items = this.items()
                  const item = this.openAtEnd ? items.at(-1) : items[0]
                  item?.focus({preventScroll: true})
                  this.openAtEnd = false
                }
              }
              this.onTriggerKey = event => {
                if (!["ArrowDown", "ArrowUp"].includes(event.key)) return
                event.preventDefault()
                this.openAtEnd = event.key === "ArrowUp"
                if (!this.el.matches(":popover-open")) this.el.showPopover()
              }
              this.onMenuKey = event => {
                const items = this.items()
                const current = items.indexOf(document.activeElement)
                let next
                if (event.key === "ArrowDown") next = (current + 1) % items.length
                if (event.key === "ArrowUp") next = (current - 1 + items.length) % items.length
                if (event.key === "Home") next = 0
                if (event.key === "End") next = items.length - 1
                if (next !== undefined) {
                  event.preventDefault()
                  items[next]?.focus()
                } else if (event.key === "Escape") {
                  event.preventDefault()
                  this.el.hidePopover()
                  this.trigger?.focus({preventScroll: true})
                } else if (event.key === "Tab") {
                  this.el.hidePopover()
                }
              }
              this.onItemClick = event => {
                if (event.target.closest('[role="menuitem"]') && this.el.matches(":popover-open")) {
                  this.el.hidePopover()
                }
              }
              this.el.addEventListener("toggle", this.onToggle)
              this.el.addEventListener("keydown", this.onMenuKey)
              this.el.addEventListener("click", this.onItemClick)
              this.trigger?.addEventListener("keydown", this.onTriggerKey)
            },
            destroyed() {
              this.el.removeEventListener("toggle", this.onToggle)
              this.el.removeEventListener("keydown", this.onMenuKey)
              this.el.removeEventListener("click", this.onItemClick)
              this.trigger?.removeEventListener("keydown", this.onTriggerKey)
            },
            items() { return [...this.el.querySelectorAll('[role="menuitem"]:not(:disabled)')] },
          }
        </script>
      </div>
    </div>
    """
  end
end
