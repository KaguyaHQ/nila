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
  attr :row_class, :any, default: nil, doc: "fn item -> extra class string for the <tr>"
  attr :empty?, :any, default: nil, doc: "force the empty state (required for streams)"
  attr :min_width, :string, default: nil, doc: "e.g. min-w-[760px] for horizontal scroll"

  attr :dense, :boolean,
    default: false,
    doc:
      "tighter rows, for working-sheet material read in bulk (the GSTR-1 workings)\n    rather than a worklist of rows that each want a decision"

  attr :flat, :boolean,
    default: false,
    doc:
      "no shadow, for reference material — elevation is for tables that hold a\n    decision, and six shadowed surfaces in one section rank nothing"

  attr :sticky_header, :string,
    default: nil,
    doc:
      "top-offset class (e.g. \"xl:top-14\") — keeps the header row pinned while the\n    page scrolls. Applies at xl+ only: sticky needs the wrapper's horizontal overflow\n    relaxed, so narrow screens keep their scroll and wide screens get the pinned header"

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
      "bg-base-100 border-base-300 rounded-box overflow-x-auto border",
      !@flat && "shadow-moon",
      @sticky_header && "xl:overflow-x-visible",
      @class
    ]}>
      <div :if={@is_empty?} class="text-base-content/60 text-small px-4 py-12 text-center">
        {render_slot(@empty)}
      </div>
      <table :if={!@is_empty?} class={["text-small w-full text-left", @min_width]}>
        <thead class={[
          "bg-base-200 text-base-content/55 text-label uppercase",
          @sticky_header && ["xl:sticky xl:z-10", @sticky_header]
        ]}>
          <tr>
            <th
              :for={col <- @col}
              class={[
                "font-semibold",
                (@dense && "px-3 py-2") || "px-4 py-3",
                col[:align] == "right" && "text-right tabular-nums"
              ]}
            >
              {col[:label]}
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={@stream? && "stream"} class="divide-base-200 divide-y">
          <%!-- The click command is computed once and drives everything: the
                pointer, the hover, the keyboard. A row_click that returns nil
                for some rows (the workings' diff rows) must not leave those rows
                wearing a cursor that promises a click they don't have. --%>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={[
              "transition-colors",
              row_command(@row_click, @row_item, row) && "hover:bg-base-200/60 cursor-pointer",
              @row_class && @row_class.(@row_item.(row))
            ]}
            phx-click={row_command(@row_click, @row_item, row)}
            phx-keydown={row_command(@row_click, @row_item, row)}
            phx-key={row_command(@row_click, @row_item, row) && "Enter"}
            tabindex={row_command(@row_click, @row_item, row) && "0"}
            role={row_command(@row_click, @row_item, row) && "button"}
          >
            <td
              :for={col <- @col}
              class={[
                "align-top",
                (@dense && "px-3 py-1.5") || "px-4 py-3.5",
                col[:align] == "right" && "text-right tabular-nums",
                col[:class]
              ]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp row_command(nil, _row_item, _row), do: nil
  defp row_command(row_click, row_item, row), do: row_click.(row_item.(row))

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
