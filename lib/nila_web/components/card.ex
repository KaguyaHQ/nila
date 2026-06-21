defmodule NilaWeb.Components.Card do
  @moduledoc """
  Moonlight content card and KPI stat tile.
  """
  use Phoenix.Component

  @doc """
  Renders a moonlight content card: a soft-shadowed surface with a 1px hairline
  border and `rounded-box` corners. Pass `class` to adjust padding/layout and
  any global attrs (e.g. `id`) flow through.

  ## Examples

      <.card id="work-order-header" class="space-y-4">…</.card>
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["rounded-box border border-base-300 bg-base-100 p-5 shadow-moon", @class]} {@rest}>
      {render_slot(@inner_block)}
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
    <div
      class={["rounded-box border border-base-300 bg-base-100 px-4 py-3 shadow-moon", @class]}
      {@rest}
    >
      <div class="text-label font-medium uppercase text-base-content/60">{@label}</div>
      <div
        id={@value_id}
        class={[
          "mt-1 text-base-content",
          if(@figure,
            do: "font-display text-h3 font-normal leading-none tabular-nums",
            else: "text-h4 font-semibold"
          )
        ]}
      >
        {render_slot(@inner_block)}
      </div>
      <div :if={@caption != []} class="mt-2 text-fine text-base-content/55">
        {render_slot(@caption)}
      </div>
    </div>
    """
  end
end
