defmodule NilaWeb.Components.LedgerPicker do
  @moduledoc "Searchable single-select field and panel for Tally ledger identities."

  use Phoenix.Component

  import NilaWeb.Components.Button
  import NilaWeb.Components.Input
  import NilaWeb.Components.SelectableList

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :prompt, :string, required: true
  attr :value, :string, default: nil
  attr :options, :list, required: true
  attr :picker, :string, required: true
  attr :panel_id, :string, required: true
  attr :disabled, :boolean, default: false
  attr :hide_label, :boolean, default: false
  attr :on_open, :string, required: true

  def ledger_picker_field(assigns) do
    selected_label =
      Enum.find_value(assigns.options, fn
        {label, identity} when identity == assigns.value -> label
        _option -> nil
      end)

    assigns = assign(assigns, :selected_label, selected_label)

    ~H"""
    <.field_shell id={@id} label={@label} hide_label={@hide_label}>
      <.input id={"#{@id}-value"} type="hidden" name={@name} value={@value} />
      <.picker_trigger
        id={@id}
        full_width
        placeholder={is_nil(@selected_label)}
        disabled={@disabled}
        aria-labelledby={"#{@id}-label"}
        aria-controls={@panel_id}
        popovertarget={@panel_id}
        phx-click={@on_open}
        phx-value-picker={@picker}
      >
        {@selected_label || @prompt}
      </.picker_trigger>
    </.field_shell>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :options, :list, required: true
  attr :selected_identity, :string, default: nil
  attr :on_filter, :string, required: true
  attr :on_submit, :string, required: true
  attr :on_select, :string, required: true
  attr :on_close, :string, required: true

  def ledger_picker_panel(assigns) do
    ~H"""
    <.select_panel
      id={@id}
      title={@title}
      filter_value={@form[:query].value || ""}
      on_close={@on_close}
    >
      <:search>
        <.form for={@form} id={"#{@id}-search-form"} phx-change={@on_filter} phx-submit={@on_submit}>
          <.input
            field={@form[:query]}
            type="search"
            placeholder="Search ledger names"
            aria-label="Search ledger names"
            aria-controls={"#{@id}-options"}
            autocomplete="off"
            phx-debounce="100"
            data-selectable-input
          />
        </.form>
      </:search>

      <.selectable_listbox id={"#{@id}-options"} label="Tally ledgers">
        <p :if={@options == []} class="p-block text-ink-muted text-ui">
          No ledgers match this search.
        </p>
        <.selectable_option
          :for={{label, identity} <- @options}
          id={"#{@id}-option-#{option_dom_id(identity)}"}
          selected={identity == @selected_identity}
          phx-click={@on_select}
          phx-value-identity={identity}
          popovertarget={@id}
          popovertargetaction="hide"
        >
          {label}
        </.selectable_option>
      </.selectable_listbox>
    </.select_panel>
    """
  end

  @doc "Opens a ledger picker through its field trigger so the panel stays field-anchored."
  attr :id, :string, required: true
  attr :trigger_id, :string, required: true
  slot :inner_block, required: true

  def ledger_picker_shortcut(assigns) do
    ~H"""
    <.button
      id={@id}
      type="button"
      variant="outline"
      phx-hook=".LedgerPickerShortcut"
      data-trigger-id={@trigger_id}
    >
      {render_slot(@inner_block)}
    </.button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LedgerPickerShortcut">
      export default {
        mounted() {
          this.onClick = () => {
            const trigger = document.getElementById(this.el.dataset.triggerId)
            if (!trigger || trigger.disabled) return

            trigger.scrollIntoView({block: "nearest", inline: "nearest"})
            window.requestAnimationFrame(() => trigger.click())
          }
          this.el.addEventListener("click", this.onClick)
        },
        destroyed() {
          this.el.removeEventListener("click", this.onClick)
        }
      }
    </script>
    """
  end

  defp option_dom_id(identity) do
    identity
    |> to_string()
    |> :erlang.phash2()
    |> Integer.to_string()
  end
end
