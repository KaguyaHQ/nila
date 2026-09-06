defmodule NilaWeb.Components.Card do
  @moduledoc """
  Radix-calibrated content surface and Nila KPI tile.
  """
  use Phoenix.Component

  @doc """
  Renders the canonical Nila surface. `padding` owns internal geometry; `class`
  is reserved for content layout such as stacks, clipping, or dividers.

  ## Examples

      <.card id="work-order-header" class="space-y-block">…</.card>
  """
  attr :padding, :string, default: "standard", values: ~w(none compact standard roomy)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["nila-card", @class]} data-padding={@padding} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "A panel heading aligned with standard card content; actions retain their own control recipe."
  attr :title, :string, required: true
  attr :rest, :global
  slot :inner_block
  slot :actions

  def card_header(assigns) do
    ~H"""
    <div
      class="border-rule flex flex-wrap items-center justify-between gap-4 border-b px-6 py-4"
      {@rest}
    >
      <div class="min-w-0">
        <h2 class="text-ui font-medium">{@title}</h2>
        {render_slot(@inner_block)}
      </div>
      <div :if={@actions != []}>{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  Renders a small KPI tile — an uppercase label over a figure — in the moonlight
  card shell. Pass `value_id` when the figure needs a DOM id (e.g. for tests or
  LiveView targeting).

  ## Examples

      <.stat_card label="Work orders shown" value_id="work-orders-count">{@work_order_count}</.stat_card>
  """
  attr :label, :string, required: true
  attr :value_id, :string, default: nil

  attr :figure, :boolean,
    default: false,
    doc: "render the value as a large serif tabular figure (money / headline KPIs)"

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :caption, doc: "a quiet line under the figure (e.g. \"across 12 active quotes\")"

  def stat_card(assigns) do
    ~H"""
    <div class={["nila-card", @class]} data-padding="compact" {@rest}>
      <div class="text-ink-subtle text-label font-medium uppercase">{@label}</div>
      <div
        id={@value_id}
        class={[
          "text-base-content mt-1",
          if(@figure,
            do: "font-display text-h3 leading-none font-normal tabular-nums",
            else: "text-h4 font-semibold"
          )
        ]}
      >
        {render_slot(@inner_block)}
      </div>
      <div :if={@caption != []} class="text-ink-subtle text-ui mt-2">
        {render_slot(@caption)}
      </div>
    </div>
    """
  end
end
