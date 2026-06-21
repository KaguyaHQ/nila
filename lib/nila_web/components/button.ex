defmodule NilaWeb.Components.Button do
  @moduledoc """
  Button component with navigation support, variants, and sizes.
  """
  use Phoenix.Component

  @variants %{
    "primary" => "btn-primary",
    "soft" => "btn-soft",
    "ghost" => "btn-ghost",
    "outline" => "btn-outline",
    "error" => "btn-error",
    "success" => "btn-success",
    "neutral" => "btn-neutral"
  }

  @sizes %{
    "xs" => "btn-xs",
    "sm" => "btn-sm",
    "md" => "",
    "lg" => "btn-lg"
  }

  @doc """
  Renders a button with navigation support.

  The `class` attr is additive — it is appended after the variant/size classes
  for one-off overrides (e.g. `text-error`, `gap-1`, `w-full`).

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="soft">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form target rel)

  attr :variant, :string,
    default: "primary",
    values: ~w(primary soft ghost outline error success neutral)

  attr :size, :string, default: "md", values: ~w(xs sm md lg)
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :class, [
        "btn",
        Map.fetch!(@variants, assigns.variant),
        Map.fetch!(@sizes, assigns.size),
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end
end
