defmodule NilaWeb.Components.SelectableList do
  @moduledoc """
  Shared listbox anatomy for searchable single-select controls.

  The combobox retains DOM focus while `SelectableList` moves `data-active`
  between options through `aria-activedescendant`. Selection remains a separate,
  server-rendered state.
  """
  use Phoenix.Component

  import NilaWeb.Components.Icon, only: [icon: 1]

  @doc "Renders a Radix-calibrated trigger for a searchable picker panel."
  attr :id, :string, required: true
  attr :disabled, :boolean, default: false
  attr :placeholder, :boolean, default: false
  attr :full_width, :boolean, default: false

  attr :rest, :global, include: ~w(title popovertarget popovertargetaction phx-click phx-value-id)

  slot :inner_block, required: true

  def picker_trigger(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class="nila-picker-trigger"
      data-placeholder={@placeholder}
      data-full-width={@full_width}
      disabled={@disabled}
      aria-haspopup="dialog"
      popovertargetaction={@rest[:popovertarget] && "toggle"}
      {@rest}
    >
      <span class="nila-picker-trigger-inner">{render_slot(@inner_block)}</span>
      <.icon name="hero-chevron-down-mini" class="nila-picker-trigger-icon size-4" />
    </button>
    """
  end

  @doc "Renders an anchored, light-dismiss panel for searchable single selection."
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :filter_value, :string, default: ""
  attr :on_close, :string, default: nil
  attr :controlled, :boolean, default: false
  attr :open, :boolean, default: false
  attr :generation, :integer, default: 0
  attr :trigger_id, :string, default: nil
  attr :picker, :string, default: nil
  slot :search
  slot :inner_block, required: true

  def select_panel(assigns) do
    ~H"""
    <div
      id={@id}
      popover="auto"
      role="dialog"
      aria-labelledby={"#{@id}-title"}
      class="nila-picker"
      phx-hook=".SelectPanelPopover"
      data-on-close={@on_close}
      data-controlled={@controlled}
      data-open={@open}
      data-generation={@generation}
      data-trigger-id={@trigger_id}
      data-picker={@picker}
    >
      <header class="nila-picker-header">
        <h3 id={"#{@id}-title"} class="text-base-content text-ui font-semibold">{@title}</h3>
      </header>
      <div
        id={"#{@id}-navigation"}
        class="nila-picker-body"
        phx-hook="SelectableList"
        data-loop="true"
        data-filter-value={@filter_value}
      >
        <div :if={@search != []} class="nila-picker-search">{render_slot(@search)}</div>
        <div class="nila-picker-options">{render_slot(@inner_block)}</div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SelectPanelPopover">
        export default {
          mounted() {
            this.wasOpen = false
            this.activeTrigger = null
            this.anchorName = `--${this.el.id}-anchor`
            this.onToggle = event => {
              if (event.newState === "open") {
                this.wasOpen = true
                this.syncCombobox(true)
                this.focusInput()
              } else if (this.wasOpen) {
                this.wasOpen = false
                this.syncCombobox(false)
                this.restoreTriggerFocus()

                if (this.el.dataset.onClose && this.shouldReportClose()) {
                  this.pushEvent(this.el.dataset.onClose, this.eventIdentity())
                }
              }
            }
            this.el.addEventListener("toggle", this.onToggle)
            this.syncControlled()
          },
          updated() {
            this.syncControlled()
          },
          destroyed() {
            this.el.removeEventListener("toggle", this.onToggle)
            this.releaseTrigger()
          },
          focusInput() {
            window.requestAnimationFrame(() => this.el.querySelector("[data-selectable-input]")?.focus())
          },
          controlled() {
            return this.el.hasAttribute("data-controlled")
          },
          openRequested() {
            return this.el.hasAttribute("data-open")
          },
          shouldReportClose() {
            return !this.controlled() || this.openRequested()
          },
          eventIdentity() {
            return {
              picker: this.el.dataset.picker,
              generation: this.el.dataset.generation
            }
          },
          syncControlled() {
            if (!this.controlled()) {
              if (this.el.matches(":popover-open")) this.focusInput()
              return
            }

            if (this.openRequested()) {
              this.openControlled()
            } else {
              this.closeControlled()
            }
          },
          openControlled() {
            const trigger = document.getElementById(this.el.dataset.triggerId)
            if (!trigger) return

            if (trigger !== this.activeTrigger) {
              this.releaseTrigger()
              this.activeTrigger = trigger
            }

            trigger.style.setProperty("anchor-name", this.anchorName)
            this.el.style.setProperty("position-anchor", this.anchorName)
            trigger.setAttribute("aria-expanded", "true")
            trigger.scrollIntoView({block: "nearest", inline: "nearest"})

            if (!this.el.matches(":popover-open")) this.el.showPopover()
            this.syncCombobox(true)
            this.focusInput()
          },
          closeControlled() {
            if (this.el.matches(":popover-open")) this.el.hidePopover()
            this.syncCombobox(false)
            this.releaseTrigger()
          },
          syncCombobox(expanded) {
            this.el
              .querySelector("[data-selectable-input]")
              ?.setAttribute("aria-expanded", String(expanded))
          },
          restoreTriggerFocus() {
            if (this.controlled()) this.activeTrigger?.focus({preventScroll: true})
          },
          releaseTrigger() {
            if (!this.activeTrigger) return
            this.activeTrigger.setAttribute("aria-expanded", "false")
            this.activeTrigger.style.removeProperty("anchor-name")
            this.activeTrigger = null
            this.el.style.removeProperty("position-anchor")
          }
        }
      </script>
    </div>
    """
  end

  @doc "Renders the listbox container consumed by the shared SelectableList hook."
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :rest, :global
  slot :inner_block, required: true

  def selectable_listbox(assigns) do
    ~H"""
    <div
      id={@id}
      class="nila-selectable-listbox"
      role="listbox"
      aria-label={@label}
      data-selectable-list
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders an option whose selected and keyboard-active states remain distinct.

  Navigation attributes such as `navigate`, `patch`, and `href` render a link.
  Without a navigation destination, the option renders a button for actions
  such as dismissing a panel. The option itself owns geometry, state attributes,
  and the trailing metadata treatment.
  """
  attr :id, :string, required: true
  attr :selected, :boolean, default: false
  attr :active, :boolean, default: false
  attr :aria_current, :string, default: nil

  attr :rest, :global,
    include: ~w(href navigate patch method download target rel popovertarget popovertargetaction)

  slot :inner_block, required: true
  slot :meta

  def selectable_option(%{rest: rest} = assigns) do
    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link
        id={@id}
        class="nila-selectable-option"
        data-state={if(@selected, do: "selected", else: "idle")}
        data-active={@active || nil}
        aria-current={@aria_current}
        aria-selected={to_string(@selected)}
        role="option"
        tabindex="-1"
        data-selectable-option
        {@rest}
      >
        <span class="truncate font-medium">{render_slot(@inner_block)}</span>
        <span :if={@meta != []} class="text-ink-subtle">{render_slot(@meta)}</span>
      </.link>
      """
    else
      ~H"""
      <button
        type="button"
        id={@id}
        class="nila-selectable-option"
        data-state={if(@selected, do: "selected", else: "idle")}
        data-active={@active || nil}
        aria-current={@aria_current}
        aria-selected={to_string(@selected)}
        role="option"
        tabindex="-1"
        data-selectable-option
        {@rest}
      >
        <span class="truncate font-medium">{render_slot(@inner_block)}</span>
        <span :if={@meta != []} class="text-ink-subtle">{render_slot(@meta)}</span>
      </button>
      """
    end
  end
end
