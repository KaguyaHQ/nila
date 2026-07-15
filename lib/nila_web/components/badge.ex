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

  # Literal class strings so Tailwind's scanner keeps them — an interpolated
  # `badge-#{@variant}` is invisible to the scanner and gets purged, which
  # silently renders every badge grey.
  @variants %{
    "primary" => "badge-primary",
    "secondary" => "badge-secondary",
    "accent" => "badge-accent",
    "neutral" => "badge-neutral",
    "info" => "badge-info",
    "success" => "badge-success",
    "warning" => "badge-warning",
    "error" => "badge-error",
    "ghost" => "badge-ghost"
  }

  def badge(assigns) do
    assigns = assign(assigns, :variant_class, Map.fetch!(@variants, assigns.variant))

    ~H"""
    <span class={["badge badge-soft text-fine font-semibold", @variant_class, @class]}>
      {render_slot(@inner_block)}
    </span>
    """
  end
end
