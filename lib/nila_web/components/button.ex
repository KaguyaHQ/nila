defmodule NilaWeb.Components.Button do
  @moduledoc """
  Radix-calibrated button with navigation support and Nila semantic variants.
  """
  use Phoenix.Component

  @doc """
  Renders a button with navigation support.

  The component owns typography and geometry. Callers select only meaning,
  prominence, and whether the control fills its container.

  ## Examples

      <.button>Send!</.button>
      <.button type="submit" variant="soft">Send!</.button>
      <.button href={~p"/"}>Home</.button>
  """
  attr :rest, :global,
    include:
      ~w(href method download name value disabled type form target rel popovertarget popovertargetaction)

  attr :variant, :string,
    default: "primary",
    values: ~w(primary soft ghost outline error success neutral)

  attr :size, :string, default: "sm", values: ~w(xs sm lg)
  attr :full_width, :boolean, default: false
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    if rest[:href] do
      ~H"""
      <.link
        class={["nila-button", @full_width && "w-full"]}
        data-variant={@variant}
        data-size={@size}
        {@rest}
      >
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button
        class={["nila-button", @full_width && "w-full"]}
        data-variant={@variant}
        data-size={@size}
        {@rest}
      >
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  attr :rest, :global, include: ~w(href method download target rel)

  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc "Renders inline accent text navigation with the shared Radix link recipe."
  def text_link(assigns) do
    ~H"""
    <.link class={["nila-link", @class]} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

end
