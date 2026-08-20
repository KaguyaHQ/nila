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

  attr :rest, :global, include: ~w(title popovertarget popovertargetaction phx-click phx-value-id)

  slot :inner_block, required: true

  def picker_trigger(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class="nila-picker-trigger"
      data-placeholder={@placeholder}
      disabled={@disabled}
      aria-haspopup="dialog"
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
            this.onToggle = event => {
              if (event.newState === "open") this.focusInput()
            }
            this.el.addEventListener("toggle", this.onToggle)
          },
          updated() {
            if (this.el.matches(":popover-open")) this.focusInput()
          },
          destroyed() {
            this.el.removeEventListener("toggle", this.onToggle)
          },
          focusInput() {
            window.requestAnimationFrame(() => this.el.querySelector("[data-selectable-input]")?.focus())
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
