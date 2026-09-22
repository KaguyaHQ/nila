defmodule NilaWeb.Components.Gst.Month.HsnSummary do
  use NilaWeb, :html

  @moduledoc """
  Table 12 HSN display and change highlighting used by the sales workspace.
  HSN rows retain links to the invoices contributing to each total.
  """

  alias Nila.Gst.Sales.Invoice
  alias Nila.Gst.Sales.Gstr1
  alias NilaWeb.Components.Gst.Month.Helpers

  @doc "Registered HSN contributor rows and unregistered aggregates for JSON presentation."
  def detail_rows(derived, invoices) do
    assigns = %{
      hsn:
        Gstr1.hsn_summary(
          Enum.filter(
            invoices,
            &(Invoice.recipient_registration(&1) == "registered" and
                not is_nil(Gstr1.filing_table(&1)))
          )
        ),
      buyers: buyers_by_inum(invoices),
      invoice_refs: invoice_refs_by_inum(invoices)
    }

    %{
      registered: hsn_rows(assigns),
      unregistered: get_in(derived || %{}, ["hsn", "hsn_b2c"]) || []
    }
  end

  @doc "The complete Table 12 output, with expandable invoice contributors."
  attr :derived, :map, required: true
  attr :invoices, :list, required: true
  attr :rippled, :any, default: MapSet.new()
  attr :ripple_seq, :integer, default: 0
  attr :expanded, :any, default: MapSet.new()

  def hsn_summary(assigns) do
    assigns =
      assigns
      |> assign(:hsn_b2c, get_in(assigns.derived, ["hsn", "hsn_b2c"]) || [])
      |> assign(
        :hsn,
        Gstr1.hsn_summary(
          Enum.filter(
            assigns.invoices,
            &(Invoice.recipient_registration(&1) == "registered" and
                not is_nil(Gstr1.filing_table(&1)))
          )
        )
      )
      |> assign(:buyers, buyers_by_inum(assigns.invoices))
      |> assign(:invoice_refs, invoice_refs_by_inum(assigns.invoices))

    assigns = assign(assigns, :hsn_rows, hsn_rows(assigns))

    ~H"""
    <div id="gstr1-table-12-rows" class="space-y-block">
      <div :if={@hsn_b2c != []} id="gstr1-workings-hsn-b2c" class="space-y-1.5">
        <.section_label>B2C</.section_label>

        <.data_table
          id="gstr1-workings-hsn-b2c-rows"
          rows={@hsn_b2c}
          mode="scan"
          min_width="min-w-[720px]"
        >
          <:col :let={row} label="HSN/SAC" row_header>
            <div class="flex items-center gap-2">
              <span class="font-mono">{row["hsn_sc"]}</span>
            </div>
          </:col>

          <:col :let={row} label="Description">{row["desc"] || "—"}</:col>

          <:col :let={row} label="UQC">{row["uqc"]}</:col>

          <:col :let={row} label="Quantity" align="right">{row["qty"]}</:col>

          <:col :let={row} label="Rate" align="right">{Helpers.percent(row["rt"])}</:col>

          <:col :let={row} label="Taxable" align="right">{Helpers.amount(row["txval"])}</:col>

          <:col :let={row} label="Output tax" align="right">{Helpers.amount(detail_tax(row))}</:col>
        </.data_table>
      </div>

      <div :if={@hsn != []} id="gstr1-workings-hsn" class="space-y-1.5">
        <.section_label>B2B and registered notes</.section_label>

        <.data_table
          id="gstr1-workings-hsn-rows"
          rows={@hsn_rows}
          row_id={& &1.id}
          row_class={fn row -> row_class(row, @rippled, @ripple_seq, @expanded) end}
          row_click={&row_click/1}
          min_width="min-w-[620px]"
          mode="scan"
        >
          <:col :let={row} label="HSN/SAC" row_header>
            <div :if={row.kind == :node} class="flex items-center gap-2">
              <.chevron open={MapSet.member?(@expanded, row.id)} />
              <span class="text-base-content font-mono font-medium whitespace-nowrap">{row.hsn || "—"}</span>
            </div>
             <.contrib_cell :if={row.kind == :contrib} row={row} />
          </:col>

          <:col :let={row} label="Description">
            <span
              :if={row.kind == :node}
              class="text-ink-subtle block max-w-72 truncate"
              title={row.description}
            >
              {row.description || "Official description unavailable"}
            </span>
          </:col>

          <:col :let={row} label="Rate" align="right">
            <span :if={row.kind == :node} class="text-ink-subtle">
              {Helpers.percent(row.rate)}
            </span>
          </:col>

          <:col :let={row} label="Invoices" align="right">
            <span :if={row.kind == :node} class="text-ink-subtle">{row.count}</span>
          </:col>

          <:col :let={row} label="Taxable" align="right">
            <.amount_cell row={row} value={row[:taxable]} />
          </:col>

          <:col :let={row} label="Output tax" align="right">
            <.amount_cell row={row} value={row[:tax]} />
          </:col>
        </.data_table>
      </div>
    </div>
    """
  end

  @doc "The HSN row IDs whose values changed after a correction."
  def changed_nodes(old, new) when is_map(old) and is_map(new) do
    MapSet.new(changed(hsn_index(old), hsn_index(new)))
  end

  def changed_nodes(_old, _new), do: MapSet.new()

  defp ripple_class(rippled, seq, node_id) do
    MapSet.member?(rippled, node_id) && "workings-ripple-#{rem(seq, 2)}"
  end

  defp changed(old_index, new_index),
    do: for({id, node} <- new_index, old_index[id] != node, do: id)

  # "num" is the row's position, which shifts when unrelated rows come and go —
  # a node ripples for its own value, not its neighbours'.
  defp hsn_index(derived) do
    derived
    |> get_in(["hsn", "hsn_b2b"])
    |> List.wrap()
    |> Map.new(&{hsn_node_id(&1), Map.delete(&1, "num")})
  end

  def hsn_node_ids(invoices, code) do
    invoices
    |> Gstr1.hsn_summary()
    |> Enum.filter(&(&1["hsn_sc"] == code))
    |> Enum.map(&hsn_node_id/1)
  end

  defp hsn_node_id(row),
    do: dom_id("gstr1-workings-hsn-#{row["hsn_sc"] || "none"}-#{trim_rate(row["rt"])}")

  defp trim_rate(rate) when is_number(rate) do
    if rate == trunc(rate), do: trunc(rate), else: rate
  end

  defp trim_rate(rate), do: rate

  # These ids are interpolated into CSS selectors by the expand toggle, so they
  # have to survive `querySelectorAll`. A 0.25% rate (cgst 0.125 + sgst 0.125 —
  # a real GST rate) would otherwise put a `.` in the id,
  # make the selector invalid, and the row would silently do nothing on click.
  defp dom_id(raw), do: String.replace(raw, ~r/[^A-Za-z0-9]+/, "-")

  slot :inner_block, required: true

  defp section_label(assigns) do
    ~H"""
    <div class="text-ink-subtle text-label font-semibold uppercase">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :open, :boolean, default: false

  defp chevron(assigns) do
    ~H"""
    <.icon
      name="hero-chevron-right-mini"
      class={[
        "text-ink-faint size-4 shrink-0 transition-transform",
        @open && "rotate-90"
      ]}
    />
    """
  end

  attr :row, :map, required: true

  # Level 2 → level 3 of the pyramid: a contributor row is the invoice, and
  # clicking it opens the modal where the scan and the arithmetic sit side by
  # side. Indented under its aggregate, carrying what it put into that
  # aggregate — never a bare number floating under a heading.
  defp contrib_cell(assigns) do
    ~H"""
    <div class="flex max-w-80 min-w-0 items-baseline gap-2 pl-6">
      <span class="nila-workings-reference shrink-0 font-mono">{@row.inum}</span>
      <span :if={@row.label not in [nil, ""]} class="text-ink-subtle truncate" title={@row.label}>
        {@row.label}
      </span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :value, :any, required: true

  defp amount_cell(assigns) do
    ~H"""
    <span
      :if={is_number(@value)}
      class={if @row.kind == :node, do: "text-ink font-medium", else: "text-ink-muted"}
    >
      {Helpers.amount(@value)}
    </span>
    """
  end

  # Contributor rows ship with the page and hide until their aggregate is
  # opened. Which buckets are open is server state, not an inline style: a
  # `JS.toggle` writes `display` onto the node, and the next patch — confirming
  # an issue, accepting a difference, a pile landing on the PubSub — syncs that
  # attribute away and silently re-collapses every bucket the reviewer opened.
  # Losing his place because something else on the page moved is worse than the
  # round trip, and this way the expansion is testable.
  defp row_class(%{kind: :node} = row, rippled, seq, _expanded),
    do: ripple_class(rippled, seq, row.id) || ""

  defp row_class(row, _rippled, _seq, expanded) do
    [
      "bg-quiet contrib-of-#{row.parent}",
      if(MapSet.member?(expanded, row.parent), do: "", else: "hidden")
    ]
  end

  defp row_click(%{kind: :node} = row),
    do: JS.push("toggle-workings-node", value: %{node: row.id})

  defp row_click(%{kind: :contrib} = row),
    do: JS.push("select-invoice", value: %{inum: row.ref})

  defp hsn_rows(assigns) do
    Enum.flat_map(assigns.hsn, fn row ->
      id = hsn_node_id(row)
      contribs = List.wrap(row["contribs"])

      node = %{
        kind: :node,
        id: id,
        hsn: row["hsn_sc"],
        description: row["description"],
        rate: row["rt"],
        count: length(contribs),
        taxable: row["txval"],
        tax: hsn_tax(row)
      }

      [node | contrib_rows(contribs, id, assigns.buyers, assigns.invoice_refs)]
    end)
  end

  defp contrib_rows(contribs, parent, buyers, invoice_refs) do
    map_with_inum_occurrence(contribs, fn contrib, occurrence ->
      ref = invoice_ref(invoice_refs, contrib["inum"], occurrence)

      %{
        kind: :contrib,
        id: contrib_id(parent, ref),
        parent: parent,
        inum: contrib["inum"],
        ref: ref,
        label: buyers[contrib["inum"]],
        taxable: contrib["txval"],
        tax: contrib["tax"]
      }
    end)
  end

  defp map_with_inum_occurrence(items, mapper) do
    {rows, _counts} =
      Enum.map_reduce(items, %{}, fn item, counts ->
        inum = item["inum"]
        occurrence = Map.get(counts, inum, 0)
        {mapper.(item, occurrence), Map.put(counts, inum, occurrence + 1)}
      end)

    rows
  end

  defp invoice_ref(invoice_refs, inum, occurrence) do
    case Map.get(invoice_refs, inum, []) do
      [_single] -> inum
      refs -> Enum.at(refs, occurrence, inum)
    end
  end

  defp contrib_id(parent, inum), do: dom_id("#{parent}-inv-#{inum}")

  defp detail_tax(row),
    do: (row["camt"] || 0) + (row["samt"] || 0) + (row["iamt"] || 0) + (row["csamt"] || 0)

  defp hsn_tax(row), do: detail_tax(row)

  # The rate and HSN aggregates know their contributors by invoice number; the
  # buyer is the label that makes a row recognisable, and it comes off the
  # invoice, not off any regrouping.
  defp buyers_by_inum(invoices) do
    Map.new(invoices, &{&1["invoice_number"], &1["buyer_name"]})
  end

  defp invoice_refs_by_inum(invoices) do
    Enum.group_by(invoices, & &1["invoice_number"], & &1["id"])
  end
end
