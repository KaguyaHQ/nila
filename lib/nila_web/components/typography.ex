defmodule NilaWeb.Components.Typography do
  @moduledoc """
  Typography primitives whose roles are mechanically restricted.
  """
  use Phoenix.Component

  attr :tag, :string, values: ~w(span p div), default: "span"
  attr :tone, :string, values: ~w(muted subtle moon inverse), default: "subtle"
  attr :weight, :string, values: ~w(normal medium), default: "normal"
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  slot :inner_block, required: true

  @doc "Renders timestamps, provenance, attribution, and other tertiary context."
  def context_text(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      id={@id}
      title={@title}
      class={["text-context", tone_class(@tone), weight_class(@weight)]}
    >
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  defp tone_class("muted"), do: "text-ink-muted"
  defp tone_class("subtle"), do: "text-ink-subtle"
  defp tone_class("moon"), do: "text-moon"
  defp tone_class("inverse"), do: "text-inverse/55"

  defp weight_class("normal"), do: nil
  defp weight_class("medium"), do: "font-medium"
end
