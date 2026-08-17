defmodule NilaWeb.Components.Badge do
  @moduledoc """
  Radix-calibrated status component in Nila's semantic colors.
  """
  use Phoenix.Component

  @doc """
  Renders operational state using the canonical 14px Nila badge recipe.
  `variant` selects semantic meaning; callers cannot alter its geometry.

  ## Examples

      <.badge variant="success">Completed</.badge>
  """
  attr :variant, :string,
    default: "neutral",
    values: ~w(primary secondary accent neutral info success warning error ghost)

  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class="nila-badge" data-variant={@variant}>
      {render_slot(@inner_block)}
    </span>
    """
  end
end
