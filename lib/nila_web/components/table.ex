defmodule NilaWeb.Components.Table do
  @moduledoc """
  Moonlight data table and the extracted purchase-order line-items table.
  """
  use Phoenix.Component

  @doc """
  Renders a moonlight data table: hairline rows on a bordered surface.

  The single table component for the app. Works with a plain list or a LiveView
  stream. Callers choose one product mode; they do not assemble density and row
  alignment independently:

    * `scan` — compact, vertically centred rows for registers and numeric schedules.
    * `worklist` — standard, vertically centred rows for tasks and destinations.
    * `review` — standard, top-aligned rows for multiline evidence or embedded controls.

  Exactly one `:col` must be marked `row_header`; it identifies each row to assistive
  technology. Each column also accepts `key`, `label`, `align` ("left", "center", or
  "right"), and `class`. Use a `:col_header` slot with the same `column` key when a
  header needs an interactive control instead of its text label. The optional `:toolbar`
  slot attaches contextual actions to the table surface above the column headers. The
  `:empty` slot renders when there are no rows; for streams pass `empty?` explicitly since
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
        mode="worklist"
        row_click={fn inv -> JS.navigate(~p"/invoices/\#{inv.id}") end}
        empty?={@visible_count == 0}
      >
        <:col :let={inv} label="Invoice" row_header>{inv.invoice_number}</:col>
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

  attr :mode, :string,
    required: true,
    values: ~w(scan worklist review),
    doc: "closed table recipe: scan, worklist, or review"

  attr :sticky_header, :string,
    default: nil,
    doc:
      "top-offset class (e.g. \"xl:top-14\") — keeps the header row pinned while the\n    page scrolls. Applies at xl+ only: sticky needs the wrapper's horizontal overflow\n    relaxed, so narrow screens keep their scroll and wide screens get the pinned header"

  slot :col do
    attr :key, :string
    attr :label, :string
    attr :align, :string, values: ~w(left center right)
    attr :class, :any
    attr :row_header, :boolean
  end

  slot :col_header do
    attr :column, :string, required: true
  end

  slot :toolbar
  slot :empty

  def data_table(assigns) do
    stream? = match?(%Phoenix.LiveView.LiveStream{}, assigns.rows)

    if Enum.count(assigns.col, &Map.get(&1, :row_header, false)) != 1 do
      raise ArgumentError,
            "data_table expects exactly one :col with row_header to identify each row"
    end

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
    <div class="nila-table-shell">
      <div :if={@toolbar != []} class="nila-table-toolbar">
        {render_slot(@toolbar)}
      </div>
      <div class={[
        "nila-table-scroll",
        @sticky_header && "xl:overflow-x-visible"
      ]}>
        <div :if={@is_empty?} class="text-body text-ink-muted px-4 py-12 text-center">
          {render_slot(@empty)}
        </div>
        <table
          :if={!@is_empty?}
          class={["nila-table", @min_width]}
          data-mode={@mode}
        >
          <thead class={[
            "bg-base-200 text-ink-subtle text-label uppercase",
            @sticky_header && ["xl:sticky xl:z-10", @sticky_header]
          ]}>
            <tr>
              <th
                :for={col <- @col}
                scope="col"
                class={[
                  "font-semibold",
                  column_alignment(col[:align])
                ]}
              >
                <%= if header = column_header(@col_header, col[:key]) do %>
                  {render_slot(header)}
                <% else %>
                  {col[:label]}
                <% end %>
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
              <.table_body_cell
                :for={{col, index} <- Enum.with_index(@col)}
                col={col}
                index={index}
                item={@row_item.(row)}
                href={row_href(@row_navigate, @row_item, row)}
                link_label={row_name(@row_label, @row_item, row)}
              />
            </tr>
          </tbody>
        </table>
      </div>
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

  defp column_header(headers, key), do: Enum.find(headers, &(&1.column == key))

  defp column_alignment("center"), do: "text-center"
  defp column_alignment("right"), do: "text-right tabular-nums"
  defp column_alignment(_align), do: "text-left"

  attr :col, :map, required: true
  attr :index, :integer, required: true
  attr :item, :any, required: true
  attr :href, :any, required: true
  attr :link_label, :any, required: true

  defp table_body_cell(assigns) do
    ~H"""
    <th
      :if={@col[:row_header]}
      scope="row"
      class={[column_alignment(@col[:align]), @col[:class]]}
    >
      <.table_cell_content
        col={@col}
        index={@index}
        item={@item}
        href={@href}
        link_label={@link_label}
      />
    </th>
    <td :if={!@col[:row_header]} class={[column_alignment(@col[:align]), @col[:class]]}>
      <.table_cell_content
        col={@col}
        index={@index}
        item={@item}
        href={@href}
        link_label={@link_label}
      />
    </td>
    """
  end

  attr :col, :map, required: true
  attr :index, :integer, required: true
  attr :item, :any, required: true
  attr :href, :any, required: true
  attr :link_label, :any, required: true

  defp table_cell_content(assigns) do
    ~H"""
    <%!-- Positioned, so it paints over the cells' ordinary text and takes their
          clicks; anything a row wants to keep clickable raises itself with
          `relative z-10`. --%>
    <.link
      :if={@index == 0 && @href}
      navigate={@href}
      class="absolute inset-0 z-0"
    >
      <span class="sr-only">{@link_label}</span>
    </.link>
    {render_slot(@col, @item)}
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
    <.data_table id={@id} rows={@line_items} mode="review" min_width="min-w-[720px]">
      <:col :let={line} label="Description" row_header>{line["description"]}</:col>
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
