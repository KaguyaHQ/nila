defmodule NilaWeb.Components.Table do
  @moduledoc """
  Moonlight data table and the extracted purchase-order line-items table.
  """
  use Phoenix.Component

  @doc """
  Renders a moonlight data table: hairline rows on a bordered surface.

  The single table component for the app. Works with a plain list or a LiveView
  stream. Each `:col` takes `label`, `align` ("right"), and `class`. The `:empty`
  slot renders when there are no rows; for streams pass `empty?` explicitly since
  a stream's size isn't known at render time.

  Two ways to make a row live, and the choice is not stylistic:

    * `row_navigate` — a function returning a path. The row becomes a real link
      (stretched over the row from the first cell), so middle-click, cmd-click,
      "copy link address", and screen readers all behave. **Use this whenever the
      row's job is to go somewhere.**
    * `row_click` — a function returning a JS command, for rows that *do*
      something instead: toggling a node, selecting a line.

  Nested links (a row's "edit" action) work under `row_navigate` with no
  escaping: give them `relative z-10` to sit above the stretched link and they
  keep their own destination. Under `row_click` they cannot — LiveView listens
  for both `phx-click` and `data-phx-link` on `window`, so the only way to stop
  the row's command from swallowing a nested link is `stopPropagation`, which
  also stops LiveView's own navigation and silently downgrades the link to a
  full page load. That is the trap `row_navigate` exists to close.

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

  attr :row_navigate, :any,
    default: nil,
    doc: "fn item -> path; makes the row a real link. Prefer over row_click for navigation"

  attr :row_label, :any,
    default: nil,
    doc: "fn item -> the row link's accessible name, e.g. fn c -> \"Open \#{c.name}\" end"

  attr :row_class, :any, default: nil, doc: "fn item -> extra class string for the <tr>"
  attr :empty?, :any, default: nil, doc: "force the empty state (required for streams)"
  attr :min_width, :string, default: nil, doc: "e.g. min-w-[760px] for horizontal scroll"

  attr :dense, :boolean,
    default: false,
    doc:
      "tighter rows, for working-sheet material read in bulk (the GSTR-1 workings)\n    rather than a worklist of rows that each want a decision"

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
      @sticky_header && "xl:overflow-x-visible",
      @class
    ]}>
      <div :if={@is_empty?} class="text-body text-ink-muted px-4 py-12 text-center">
        {render_slot(@empty)}
      </div>
      <table :if={!@is_empty?} class={["text-ui w-full text-left", @min_width]}>
        <thead class={[
          "bg-base-200 text-ink-subtle text-label uppercase",
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
        <tbody id={@id} phx-update={@stream? && "stream"} class="divide-base-300 divide-y">
          <%!-- The click command is computed once and drives everything: the
                pointer, the hover, the keyboard. A row_click that returns nil
                for some rows (the workings' diff rows) must not leave those rows
                wearing a cursor that promises a click they don't have. --%>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={[
              "transition-colors",
              (row_command(@row_click, @row_item, row) || row_href(@row_navigate, @row_item, row)) &&
                "hover:bg-base-200/60 cursor-pointer",
              row_href(@row_navigate, @row_item, row) && "relative",
              @row_class && @row_class.(@row_item.(row))
            ]}
            phx-click={row_command(@row_click, @row_item, row)}
            phx-keydown={row_command(@row_click, @row_item, row)}
            phx-key={row_command(@row_click, @row_item, row) && "Enter"}
            tabindex={row_command(@row_click, @row_item, row) && "0"}
            role={row_command(@row_click, @row_item, row) && "button"}
          >
            <td
              :for={{col, index} <- Enum.with_index(@col)}
              class={[
                "align-top",
                (@dense && "px-3 py-1.5") || "px-4 py-3",
                col[:align] == "right" && "text-right tabular-nums",
                col[:class]
              ]}
            >
              <%!-- Positioned, so it paints over the cells' ordinary text and
                    takes their clicks; anything a row wants to keep clickable
                    raises itself with `relative z-10`. --%>
              <.link
                :if={index == 0 && row_href(@row_navigate, @row_item, row)}
                navigate={row_href(@row_navigate, @row_item, row)}
                class="absolute inset-0 z-0"
              >
                <span class="sr-only">{row_name(@row_label, @row_item, row)}</span>
              </.link>
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

  # `relative` on the <tr> is what makes the stretched link cover the row, so a
  # row that returns no path must not get it — the link would then stretch over
  # whichever ancestor is positioned instead.
  defp row_href(nil, _row_item, _row), do: nil
  defp row_href(row_navigate, row_item, row), do: row_navigate.(row_item.(row))

  defp row_name(nil, _row_item, _row), do: nil
  defp row_name(row_label, row_item, row), do: row_label.(row_item.(row))

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
