defmodule NilaWeb.Components.Table do
  @moduledoc """
  Moonlight data table and the extracted purchase-order line-items table.
  """
  use Phoenix.Component

  @doc """
  Renders a moonlight data table: hairline rows on a soft-shadowed surface.

  The single table component for the app. Works with a plain list or a LiveView
  stream. Pass `row_click` (a function of the row item returning a JS command) to
  make the whole row navigable. Each `:col` takes `label`, `align` ("right"), and
  `class`. The `:empty` slot renders when there are no rows; for streams pass
  `empty?` explicitly since a stream's size isn't known at render time.

  ## Examples

      <.data_table
        id="invoices"
        rows={@streams.invoices}
        row_click={fn inv -> JS.navigate(~p"/invoices/\#{inv.id}") end}
        empty?={@visible_count == 0}
      >
        <:col :let={inv} label="Invoice">{inv.invoice_number}</:col>
        <:col :let={inv} label="Amount" align="right">{format_money(inv.total_paise, prefix: "₹")}</:col>
        <:empty>Nothing here.</:empty>
      </.data_table>
  """
  attr :id, :string, required: true
  attr :rows, :any, required: true
  attr :row_id, :any, default: nil, doc: "fn row -> dom id; defaults to the stream id"
  attr :row_click, :any, default: nil, doc: "fn item -> JS command, run on row click"
  attr :empty?, :any, default: nil, doc: "force the empty state (required for streams)"
  attr :min_width, :string, default: nil, doc: "e.g. min-w-[760px] for horizontal scroll"
  attr :class, :any, default: nil

  slot :col do
    attr :label, :string
    attr :align, :string
    attr :class, :any
  end

  slot :empty

  def data_table(assigns) do
    stream? = match?(%Phoenix.LiveView.LiveStream{}, assigns.rows)

    assigns =
      assigns
      |> assign(:stream?, stream?)
      |> assign(:row_id, assigns.row_id || (stream? && fn {id, _item} -> id end))
      |> assign(:row_item, if(stream?, do: fn {_id, item} -> item end, else: & &1))
      |> assign(
        :is_empty?,
        if(is_nil(assigns.empty?), do: assigns.rows == [], else: assigns.empty?)
      )

    ~H"""
    <div class={[
      "overflow-x-auto rounded-box border border-base-300 bg-base-100 shadow-moon",
      @class
    ]}>
      <div :if={@is_empty?} class="px-4 py-12 text-center text-small text-base-content/60">
        {render_slot(@empty)}
      </div>
      <table :if={!@is_empty?} class={["w-full text-left text-small", @min_width]}>
        <thead class="bg-base-200 text-label uppercase text-base-content/55">
          <tr>
            <th
              :for={col <- @col}
              class={["px-4 py-3 font-medium", col[:align] == "right" && "text-right"]}
            >
              {col[:label]}
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={@stream? && "stream"} class="divide-y divide-base-200">
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={["transition-colors", @row_click && "cursor-pointer hover:bg-base-200/60"]}
            phx-click={@row_click && @row_click.(@row_item.(row))}
          >
            <td
              :for={col <- @col}
              class={["px-4 py-3.5 align-top", col[:align] == "right" && "text-right", col[:class]]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders an extracted purchase-order line-items table.

  The data is a list of string-keyed maps from the PO extraction pipeline
  (keys: "description", "hsn_sac", "quantity", "unit", "unit_price",
  "tax_rate", "amount"). Built on `.data_table` so styling stays consistent.

  ## Examples

      <.extracted_line_items_table
        id={"po-lines-123"}
        line_items={field(artifact.data, "line_items") || []}
      />
  """
  attr :id, :string, required: true
  attr :line_items, :list, required: true, doc: "list of string-keyed maps from extraction"

  def extracted_line_items_table(assigns) do
    ~H"""
    <.data_table id={@id} rows={@line_items} min_width="min-w-[720px]">
      <:col :let={line} label="Description">{line["description"]}</:col>
      <:col :let={line} label="HSN/SAC">{line["hsn_sac"]}</:col>
      <:col :let={line} label="Qty">{line["quantity"]} {line["unit"]}</:col>
      <:col :let={line} label="Rate">{line["unit_price"]}</:col>
      <:col :let={line} label="Tax">{line["tax_rate"]}%</:col>
      <:col :let={line} label="Amount" align="right">{line["amount"]}</:col>
      <:empty>No line items read.</:empty>
    </.data_table>
    """
  end
end
