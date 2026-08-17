defmodule NilaWeb.Components.Feedback do
  @moduledoc "Inline status feedback."
  use Phoenix.Component

  import NilaWeb.Components.Icon

  attr :kind, :string, default: "info", values: ~w(info success warning error)
  attr :title, :string, default: nil
  slot :inner_block, required: true

  @doc "Renders a Radix-calibrated inline status message."
  def callout(assigns) do
    ~H"""
    <div class="nila-callout" data-kind={@kind}>
      <.icon name={callout_icon(@kind)} class="size-5 shrink-0" />
      <div>
        <p :if={@title} class="font-semibold">{@title}</p>
        <p>{render_slot(@inner_block)}</p>
      </div>
    </div>
    """
  end

  defp callout_icon("info"), do: "hero-information-circle"
  defp callout_icon("success"), do: "hero-check-circle"
  defp callout_icon("warning"), do: "hero-exclamation-triangle"
  defp callout_icon("error"), do: "hero-exclamation-circle"

  attr :size, :string, default: "sm", values: ~w(xs sm)
  attr :label, :string, default: "Working"

  @doc "Renders a finite-size indeterminate progress indicator."
  def spinner(assigns) do
    ~H"""
    <span class="nila-spinner" data-size={@size} role="status">
      <.icon name="hero-arrow-path" class="nila-spinner-icon motion-safe:animate-spin" />
      <span class="sr-only">{@label}</span>
    </span>
    """
  end

  attr :id, :string, default: nil
  attr :value, :integer, required: true
  attr :max, :integer, required: true

  @doc "Renders determinate progress using the canonical Nila track."
  def progress_bar(assigns) do
    ~H"""
    <progress id={@id} class="nila-progress" value={@value} max={@max}></progress>
    """
  end
end
