defmodule NilaWeb.Components.Badge do
  @moduledoc """
  Soft status pill component.
  """
  use Phoenix.Component

  @doc """
  Renders a soft status pill in a daisyUI semantic color. `variant` is the
  semantic token (`primary`, `success`, `warning`, `error`, `info`, `neutral`,
  `ghost`) — `badge-soft` handles border/background/text contrast.

  ## Examples

      <.badge variant="success">Completed</.badge>
  """
  attr :variant, :string, default: "neutral"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={["badge badge-soft text-fine font-semibold", "badge-#{@variant}", @class]}>
      {render_slot(@inner_block)}
    </span>
    """
  end
end
