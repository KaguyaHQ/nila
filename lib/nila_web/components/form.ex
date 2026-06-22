defmodule NilaWeb.Components.Form do
  @moduledoc """
  Settings form actions row and the standard save button.
  """
  use Phoenix.Component

  import NilaWeb.Components.Icon

  @doc """
  Renders the standard right-aligned action row for settings forms.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def form_actions(assigns) do
    ~H"""
    <div class={["flex items-center justify-end gap-2", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Submit button for settings forms. Shows a spinner and `loading` label while the
  form is in flight via `phx-disable-with`, and confirms inline rather than relying
  on a distant flash. Pass `disabled` to gate on a dirty check.
  """
  attr :id, :string, required: true
  attr :label, :string, default: "Save changes"
  attr :loading, :string, default: "Saving…"
  attr :icon, :string, default: "hero-check"
  attr :disabled, :boolean, default: false
  attr :rest, :global

  def save_button(assigns) do
    ~H"""
    <button
      type="submit"
      id={@id}
      disabled={@disabled}
      phx-disable-with={@loading}
      class="btn btn-primary btn-sm btn-soft transition-all"
      {@rest}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </button>
    """
  end
end
