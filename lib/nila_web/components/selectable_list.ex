defmodule NilaWeb.Components.SelectableList do
  @moduledoc """
  Shared listbox anatomy for searchable single-select controls.

  The combobox retains DOM focus while `SelectableList` moves `data-active`
  between options through `aria-activedescendant`. Selection remains a separate,
  server-rendered state.
  """
  use Phoenix.Component

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

  attr :rest, :global, include: ~w(href navigate patch method download target rel)

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
