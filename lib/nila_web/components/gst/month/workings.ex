defmodule NilaWeb.Components.Gst.Month.Workings do
  use NilaWeb, :html

  @moduledoc """
  The GSTR-1 workings body: the derived return rendered in the working-sheet
  shape a CA already reads — B2B party-wise, rate summary, HSN, documents
  issued.

  Renders the materialized projection (`derived_gstr1` out of
  `Nila.Gst.Sales.Workings.materialize/4`, or a sign-off snapshot) — never the
  pristine month. Every aggregate opens to the invoices that built it, each
  linking into the invoice modal, and the contributor rows come from the same
  derivation functions that build the portal JSON (`Gstr1.hsn_summary/1`,
  `Gstr1.rate_summary/1`) — this module never regroups anything, so a number
  here and the JSON beside it cannot disagree. Empty subsections are omitted
  outright: a month with no B2B shows no B2B heading.

  This is appendix-grade material: a working sheet is dense rows a CA scans in
  seconds, so every subsection is one `.data_table` and a row expands in place
  into its contributors — sixteen HSN codes are sixteen lines, not sixteen
  cards. Card treatment is for things that need a decision; the return needs
  reading. Which buckets are open is server state (`expanded`): a client-side
  `JS.toggle` writes an inline `display`, and the next patch — an issue
  confirmed, a difference accepted, a pile landing on the PubSub — syncs it
  away and re-collapses everything the reviewer had open. One round trip per
  expansion is cheaper than losing your place because something else moved.
  """

  alias Nila.Eval.Gstr1Diff
  alias Nila.Gst.Sales.Gstr1
  alias NilaWeb.Components.Gst.Month.Helpers

  attr :derived, :map, required: true
  attr :invoices, :list, required: true
  attr :diff, :any, default: nil
  attr :accepted, :any, default: MapSet.new()
  attr :locked, :boolean, default: false
  attr :rippled, :any, default: MapSet.new()
  attr :ripple_seq, :integer, default: 0
  attr :expanded, :any, default: MapSet.new()

  def workings_body(assigns) do
    assigns =
      assigns
      |> assign(:b2b, assigns.derived["b2b"] || [])
      |> assign(:rates, Gstr1.rate_summary(assigns.derived))
      |> assign(:hsn, Gstr1.hsn_summary(assigns.invoices))
      |> assign(:names, names_by_gstin(assigns.invoices))
      |> assign(:buyers, buyers_by_inum(assigns.invoices))
      |> assign(:invoice_refs, invoice_refs_by_inum(assigns.invoices))
      |> assign_diff()

    assigns =
      assigns
      |> assign(:party_rows, party_rows(assigns))
      |> assign(:rate_rows, rate_rows(assigns))
      |> assign(:hsn_rows, hsn_rows(assigns))

    ~H"""
    <div id="gstr1-workings" class="space-y-block">
      <section
        :if={@diff && @mismatches != []}
        id="gstr1-filed-comparison"
        class="space-y-block"
      >
        <div class="space-y-related">
          <h4 class="text-base-content text-body font-semibold">Compared with filed return</h4>
          <p id="gstr1-diff-summary" class="text-body text-ink-muted flex items-center gap-2">
            <.icon name="hero-exclamation-triangle-mini" class="text-warning size-4 shrink-0" />
            {diff_summary_line(@diff, @mismatches)}
          </p>
        </div>
        <div class="space-y-related">
          <.diff_row
            :for={row <- @mismatches}
            row={row}
            accepted={@accepted}
            locked={@locked}
            context={diff_context(row)}
          />
        </div>
      </section>

      <%!-- One line, once, rather than a qualifier repeated on nine column
            headers: everything below is the figure that reaches the portal. --%>
      <p id="gstr1-workings-basis" class="text-ink-subtle text-meta">
        Every figure below is what this return files — taxable value aggregated per rate bucket,
        with the tax recomputed on that total rather than summed from the extracted lines.
      </p>

      <div :if={@b2b != []} id="gstr1-workings-b2b" class="space-y-1.5">
        <.section_label>B2B — party-wise</.section_label>
        <.data_table
          id="gstr1-workings-b2b-rows"
          rows={@party_rows}
          row_id={& &1.id}
          row_class={fn row -> row_class(row, @rippled, @ripple_seq, @expanded) end}
          row_click={&row_click/1}
          min_width="min-w-[620px]"
          dense
        >
          <:col :let={row} label="Party">
            <%!-- Extraction sometimes lands a whole postal address in the buyer
                  name; a text column that sizes to its content pushes the money
                  off the right edge, so the name truncates and the full string
                  stays one hover away. --%>
            <div :if={row.kind == :node} class="flex max-w-80 items-center gap-2">
              <.chevron open={MapSet.member?(@expanded, row.id)} />
              <span class="text-base-content truncate font-medium" title={row.name}>{row.name}</span>
            </div>
            <.contrib_cell :if={row.kind == :contrib} row={row} />
          </:col>
          <:col :let={row} label="GSTIN">
            <span :if={row.kind == :node} class="text-ink-subtle font-mono">
              {row.gstin || "—"}
            </span>
          </:col>
          <:col :let={row} label="Invoices" align="right">
            <span :if={row.kind == :node} class="text-ink-subtle">{row.count}</span>
          </:col>
          <:col :let={row} label="Taxable" align="right">
            <.amount_cell row={row} value={row[:taxable]} />
          </:col>
          <%!-- Every figure in these workings is the derived per-rate bucket, not
                the sum of extracted lines. They differ by rounding, and calling
                both "Tax" is why nobody could say which one gets filed. --%>
          <:col :let={row} label="Proposed GSTR-1" align="right">
            <.amount_cell row={row} value={row[:tax]} />
          </:col>
        </.data_table>
      </div>

      <div :if={@rates != []} id="gstr1-workings-rates" class="space-y-1.5">
        <.section_label>Rate summary</.section_label>
        <.data_table
          id="gstr1-workings-rates-rows"
          rows={@rate_rows}
          row_id={& &1.id}
          row_class={fn row -> row_class(row, @rippled, @ripple_seq, @expanded) end}
          row_click={&row_click/1}
          min_width="min-w-[520px]"
          dense
        >
          <:col :let={row} label="Rate">
            <div :if={row.kind == :node} class="flex items-center gap-2">
              <.chevron open={MapSet.member?(@expanded, row.id)} />
              <span class="text-base-content font-medium">{Helpers.percent(row.rate)}</span>
            </div>
            <.contrib_cell :if={row.kind == :contrib} row={row} />
          </:col>
          <:col :let={row} label="Invoices" align="right">
            <span :if={row.kind == :node} class="text-ink-subtle">{row.count}</span>
          </:col>
          <:col :let={row} label="Taxable" align="right">
            <.amount_cell row={row} value={row[:taxable]} />
          </:col>
          <:col :let={row} label="Proposed GSTR-1" align="right">
            <.amount_cell row={row} value={row[:tax]} />
          </:col>
        </.data_table>
      </div>

      <div :if={@hsn != []} id="gstr1-workings-hsn" class="space-y-1.5">
        <.section_label>HSN summary</.section_label>
        <.data_table
          id="gstr1-workings-hsn-rows"
          rows={@hsn_rows}
          row_id={& &1.id}
          row_class={fn row -> row_class(row, @rippled, @ripple_seq, @expanded) end}
          row_click={&row_click/1}
          min_width="min-w-[620px]"
          dense
        >
          <:col :let={row} label="HSN/SAC">
            <div :if={row.kind == :node} class="flex items-center gap-2">
              <.chevron open={MapSet.member?(@expanded, row.id)} />
              <span class="text-base-content font-mono font-medium">{row.hsn || "—"}</span>
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
          <:col :let={row} label="Proposed GSTR-1" align="right">
            <.amount_cell row={row} value={row[:tax]} />
          </:col>
        </.data_table>
      </div>
    </div>
    """
  end

  defp assign_diff(%{diff: nil} = assigns), do: assign(assigns, :mismatches, [])

  defp assign_diff(assigns),
    do: assign(assigns, :mismatches, Enum.reject(assigns.diff, & &1["match"]))

  defp diff_summary_line(diff, mismatches) do
    score = Gstr1Diff.score(diff)

    "Against the filed return: #{score["matches"]} of #{score["total"]} compared fields match" <>
      " · #{length(mismatches)} differ"
  end

  attr :row, :map, required: true
  attr :accepted, :any, required: true
  attr :locked, :boolean, default: false
  attr :context, :string, default: nil

  # One field where the filed return disagrees. `accept_difference` is the
  # AUDITOR verdict as a product verb — "filed differs; ours is right" —
  # recorded append-only like every other resolution, undone the same way.
  defp diff_row(assigns) do
    assigns = assign(assigns, :target, diff_target(assigns.row))

    ~H"""
    <div class="text-body flex flex-wrap items-center gap-x-2 gap-y-1">
      <.icon
        name="hero-exclamation-triangle-mini"
        class={[
          "size-4 shrink-0",
          (MapSet.member?(@accepted, @target) && "text-ink-faint") || "text-warning"
        ]}
      />
      <span class="text-ink-muted">
        {diff_claim(@row, @context)}
      </span>
      <.button
        :if={not MapSet.member?(@accepted, @target) and not @locked}
        variant="outline"
        size="xs"
        phx-click="accept_difference"
        phx-value-target={@target}
      >
        Ours is right
      </.button>
      <span :if={MapSet.member?(@accepted, @target)} class="flex items-center gap-1.5">
        <span class="text-meta text-success font-medium">Accepted — ours is right</span>
        <.button
          :if={not @locked}
          variant="ghost"
          size="xs"
          phx-click="undo"
          phx-value-target={@target}
        >
          Undo
        </.button>
      </span>
    </div>
    """
  end

  defp diff_claim(row, nil) do
    field = row["field"]

    "#{diff_field(field)}: ours #{diff_value(field, row["derived"])} · filed #{diff_value(field, row["filed"])}"
  end

  defp diff_claim(row, context), do: "#{context} · #{diff_claim(row, nil)}"

  defp diff_context(%{"scope" => scope, "key" => key})
       when scope in ["invoice", "invoice_item"] do
    [_gstin, invoice, rate] = String.split(key, "|")
    "Invoice #{invoice} · #{rate}%"
  end

  defp diff_context(%{"scope" => "hsn", "key" => key}) do
    [code, rate] = String.split(key, "|")
    "HSN #{code} · #{rate}%"
  end

  defp diff_context(%{"scope" => "doc_issue"}), do: "Invoice series"

  defp diff_field("ctin"), do: "Counterparty GSTIN"
  defp diff_field("inum"), do: "Invoice number"
  defp diff_field("idt"), do: "Invoice date"
  defp diff_field("val"), do: "Invoice value"
  defp diff_field("pos"), do: "Place of supply"
  defp diff_field("rchrg"), do: "Reverse charge"
  defp diff_field("inv_typ"), do: "Invoice type"
  defp diff_field("rt"), do: "Rate"
  defp diff_field("txval"), do: "Taxable value"
  defp diff_field("camt"), do: "CGST"
  defp diff_field("samt"), do: "SGST"
  defp diff_field("iamt"), do: "IGST"
  defp diff_field("csamt"), do: "Cess"
  defp diff_field("hsn_sc"), do: "HSN/SAC"
  defp diff_field("from"), do: "From"
  defp diff_field("to"), do: "To"
  defp diff_field("totnum"), do: "Numbers"
  defp diff_field("net_issue"), do: "Issued"
  defp diff_field("cancel"), do: "Cancelled"

  defp diff_target(row), do: "#{row["scope"]}|#{row["key"]}|#{row["field"]}"

  defp diff_value(_field, nil), do: "—"

  defp diff_value(field, value)
       when field in ["val", "txval", "camt", "samt", "iamt", "csamt"] and is_number(value),
       do: Helpers.amount(value)

  defp diff_value("rt", value) when is_number(value), do: Helpers.percent(value)
  defp diff_value(_field, value), do: to_string(value)

  @doc """
  The workings nodes whose value a re-materialization changed, as the DOM ids
  this module renders — party cards, rate buckets, HSN rows — plus the account
  line when the month totals moved. Diffed off the same derived JSON the nodes
  render, so a resolution that leaves the return untouched (confirming an
  issue) highlights nothing.
  """
  def changed_nodes(old, new) when is_map(old) and is_map(new) do
    MapSet.new(
      changed(party_index(old), party_index(new)) ++
        changed(rate_index(old), rate_index(new)) ++
        changed(hsn_index(old), hsn_index(new)) ++
        account_nodes(old, new)
    )
  end

  def changed_nodes(_old, _new), do: MapSet.new()

  @doc "The one-shot highlight class for a node the last correction changed."
  def ripple_class(rippled, seq, node_id) do
    MapSet.member?(rippled, node_id) && "workings-ripple-#{rem(seq, 2)}"
  end

  defp changed(old_index, new_index),
    do: for({id, node} <- new_index, old_index[id] != node, do: id)

  defp party_index(derived),
    do: Map.new(List.wrap(derived["b2b"]), &{party_node_id(&1["ctin"]), &1})

  defp rate_index(derived),
    do: Map.new(Gstr1.rate_summary(derived), &{rate_node_id(&1["rate"]), &1})

  # "num" is the row's position, which shifts when unrelated rows come and go —
  # a node ripples for its own value, not its neighbours'.
  defp hsn_index(derived) do
    derived
    |> get_in(["hsn", "hsn_b2b"])
    |> List.wrap()
    |> Map.new(&{hsn_node_id(&1), Map.delete(&1, "num")})
  end

  defp account_nodes(old, new) do
    if month_value(old) == month_value(new), do: [], else: ["gstr1-account"]
  end

  defp month_value(derived) do
    derived
    |> Gstr1.rate_summary()
    |> Enum.reduce({0, 0}, fn bucket, {taxable, tax} ->
      {taxable + bucket["taxable"], tax + bucket["tax"]}
    end)
  end

  defp party_node_id(ctin), do: dom_id("gstr1-workings-party-#{ctin || "nogstin"}")

  defp rate_node_id(rate), do: dom_id("gstr1-workings-rate-#{trim_rate(rate)}")

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
  # a real GST rate) or a GSTIN-less party would otherwise put a `.` in the id,
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
    <div class="flex max-w-80 items-baseline gap-2 pl-6">
      <span class="text-primary shrink-0 font-mono">{@row.inum}</span>
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
      "bg-base-200/30 contrib-of-#{row.parent}",
      if(MapSet.member?(expanded, row.parent), do: "", else: "hidden")
    ]
  end

  defp row_click(%{kind: :node} = row),
    do: JS.push("toggle-workings-node", value: %{node: row.id})

  defp row_click(%{kind: :contrib} = row),
    do: JS.push("select-invoice", value: %{inum: row.ref})

  defp party_rows(assigns) do
    Enum.flat_map(assigns.b2b, fn party ->
      id = party_node_id(party["ctin"])
      totals = party_totals(party)

      node = %{
        kind: :node,
        id: id,
        name: assigns.names[party["ctin"]] || "Name not read",
        gstin: party["ctin"],
        count: length(party["inv"] || []),
        taxable: totals.taxable,
        tax: totals.tax
      }

      invoices =
        party["inv"]
        |> List.wrap()
        |> map_with_inum_occurrence(fn inv, occurrence ->
          inv_totals = invoice_totals(inv)
          ref = invoice_ref(assigns.invoice_refs, inv["inum"], occurrence)

          %{
            kind: :contrib,
            id: contrib_id(id, ref),
            parent: id,
            inum: inv["inum"],
            ref: ref,
            label: invoice_label(inv),
            taxable: inv_totals.taxable,
            tax: inv_totals.tax
          }
        end)

      [node | invoices]
    end)
  end

  defp rate_rows(assigns) do
    Enum.flat_map(assigns.rates, fn bucket ->
      id = rate_node_id(bucket["rate"])
      contribs = List.wrap(bucket["contribs"])

      node = %{
        kind: :node,
        id: id,
        rate: bucket["rate"],
        count: length(contribs),
        taxable: bucket["taxable"],
        tax: bucket["tax"]
      }

      [node | contrib_rows(contribs, id, assigns.buyers, assigns.invoice_refs)]
    end)
  end

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

  # Display sums of the very numbers the portal receives — reading the derived
  # JSON, never re-deriving from the invoices.
  defp party_totals(party) do
    Enum.reduce(party["inv"] || [], %{taxable: 0, tax: 0}, fn inv, acc ->
      totals = invoice_totals(inv)
      %{taxable: acc.taxable + totals.taxable, tax: acc.tax + totals.tax}
    end)
  end

  defp invoice_label(inv) do
    [inv["idt"], bucket_label(inv)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp bucket_label(inv) do
    Enum.map_join(inv["itms"] || [], " · ", fn itm ->
      det = itm["itm_det"] || %{}
      "#{Helpers.percent(det["rt"])} on #{Helpers.amount(det["txval"])}"
    end)
  end

  defp invoice_totals(inv) do
    dets = for itm <- inv["itms"] || [], do: itm["itm_det"] || %{}

    %{
      taxable: dets |> Enum.map(&(&1["txval"] || 0)) |> Enum.sum(),
      tax:
        dets
        |> Enum.map(&((&1["camt"] || 0) + (&1["samt"] || 0) + (&1["iamt"] || 0)))
        |> Enum.sum()
    }
  end

  defp hsn_tax(row), do: (row["camt"] || 0) + (row["samt"] || 0) + (row["iamt"] || 0)

  # The rate and HSN aggregates know their contributors by invoice number; the
  # buyer is the label that makes a row recognisable, and it comes off the
  # invoice, not off any regrouping.
  defp buyers_by_inum(invoices) do
    Map.new(invoices, &{&1["invoice_number"], &1["buyer_name"]})
  end

  defp invoice_refs_by_inum(invoices) do
    Enum.group_by(invoices, & &1["invoice_number"], & &1["id"])
  end

  defp names_by_gstin(invoices) do
    Enum.reduce(invoices, %{}, fn invoice, acc ->
      case {invoice["buyer_gstin"], invoice["buyer_name"]} do
        {gstin, name} when is_binary(gstin) and is_binary(name) -> Map.put_new(acc, gstin, name)
        _incomplete -> acc
      end
    end)
  end
end
