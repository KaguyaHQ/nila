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
      |> assign(:docs, doc_rows(assigns.derived))
      |> assign(:names, names_by_gstin(assigns.invoices))
      |> assign(:buyers, buyers_by_inum(assigns.invoices))
      |> assign_diff()

    assigns =
      assigns
      |> assign(:party_rows, party_rows(assigns))
      |> assign(:rate_rows, rate_rows(assigns))
      |> assign(:hsn_rows, hsn_rows(assigns))

    ~H"""
    <div id="gstr1-workings" class="space-y-block">
      <%!-- Differences lit, agreements silent. "All 45 compared fields match" is
            a trust meter — the product narrating its own diligence back at a CA
            who did not ask for a score. When the filed return agrees, the
            overlay says nothing, which is the claim. --%>
      <p
        :if={@diff && @mismatches != []}
        id="gstr1-diff-summary"
        class="text-body text-ink-muted flex items-center gap-2"
      >
        <.icon name="hero-exclamation-triangle-mini" class="text-warning size-4 shrink-0" />
        {diff_summary_line(@diff, @mismatches)}
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
            <.diff_row
              :if={row.kind == :diff}
              row={row.diff}
              accepted={@accepted}
              locked={@locked}
              class="pl-6"
            />
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
          <:col :let={row} label="Tax" align="right">
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
          <:col :let={row} label="Tax" align="right">
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
            <.diff_row
              :if={row.kind == :diff}
              row={row.diff}
              accepted={@accepted}
              locked={@locked}
              class="pl-6"
            />
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
          <:col :let={row} label="Tax" align="right">
            <.amount_cell row={row} value={row[:tax]} />
          </:col>
        </.data_table>
      </div>

      <div :if={@docs != []} id="gstr1-workings-docs" class="space-y-1.5">
        <.section_label>Documents issued</.section_label>
        <.data_table id="gstr1-workings-docs-rows" rows={@docs} min_width="min-w-[520px]" dense>
          <:col :let={doc} label="From"><span class="font-mono">{doc["from"]}</span></:col>
          <:col :let={doc} label="To"><span class="font-mono">{doc["to"]}</span></:col>
          <:col :let={doc} label="Numbers" align="right">{doc["totnum"]}</:col>
          <:col :let={doc} label="Cancelled" align="right">{doc["cancel"]}</:col>
          <:col :let={doc} label="Issued" align="right">{doc["net_issue"]}</:col>
        </.data_table>
        <.diff_row
          :for={row <- @doc_mismatches}
          row={row}
          accepted={@accepted}
          locked={@locked}
        />
      </div>

      <div :if={@unclaimed != []} id="gstr1-diff-unclaimed" class="space-y-related">
        <.section_label>Only one side holds these</.section_label>
        <.diff_row
          :for={row <- @unclaimed}
          row={row}
          accepted={@accepted}
          locked={@locked}
          context={"#{row["scope"]} #{row["key"]}"}
        />
      </div>
    </div>
    """
  end

  # The overlay is a renderer over `Nila.Eval.Gstr1Diff.rows/2` — one differ in
  # the codebase, never a second comparison here. Each mismatch is claimed by
  # the node it belongs to (invoice rows by inum, HSN rows by rolled-up code
  # prefix and rate); whatever no rendered node claims lands in the trailing
  # block, so every difference is visible somewhere. Agreements are silent.
  defp assign_diff(%{diff: nil} = assigns) do
    assigns
    |> assign(:mismatches, [])
    |> assign(:diff_by_inum, %{})
    |> assign(:hsn_mismatches, [])
    |> assign(:doc_mismatches, [])
    |> assign(:unclaimed, [])
  end

  defp assign_diff(assigns) do
    mismatches = Enum.reject(assigns.diff, & &1["match"])

    invoice_mismatches =
      Enum.filter(mismatches, &(&1["scope"] in ["invoice", "invoice_item"]))

    hsn_mismatches = Enum.filter(mismatches, &(&1["scope"] == "hsn"))

    rendered_inums =
      MapSet.new(
        for party <- assigns.derived["b2b"] || [], inv <- party["inv"] || [], do: inv["inum"]
      )

    unclaimed =
      Enum.reject(invoice_mismatches, &MapSet.member?(rendered_inums, key_part(&1, 1))) ++
        Enum.reject(hsn_mismatches, fn row ->
          Enum.any?(assigns.hsn, &hsn_claim?(row, &1))
        end)

    assigns
    |> assign(:mismatches, mismatches)
    |> assign(:diff_by_inum, Enum.group_by(invoice_mismatches, &key_part(&1, 1)))
    |> assign(:hsn_mismatches, hsn_mismatches)
    |> assign(:doc_mismatches, Enum.filter(mismatches, &(&1["scope"] == "doc_issue")))
    |> assign(:unclaimed, unclaimed)
  end

  defp diff_summary_line(diff, mismatches) do
    score = Gstr1Diff.score(diff)

    "Against the filed return: #{score["matches"]} of #{score["total"]} compared fields match" <>
      " · #{length(mismatches)} differ"
  end

  attr :row, :map, required: true
  attr :accepted, :any, required: true
  attr :locked, :boolean, default: false
  attr :context, :string, default: nil
  attr :class, :string, default: nil

  # One field where the filed return disagrees. `accept_difference` is the
  # AUDITOR verdict as a product verb — "filed differs; ours is right" —
  # recorded append-only like every other resolution, undone the same way.
  defp diff_row(assigns) do
    assigns = assign(assigns, :target, diff_target(assigns.row))

    ~H"""
    <div class={["text-body flex flex-wrap items-center gap-x-2 gap-y-1", @class]}>
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
        <span class="text-fine text-success font-medium">Accepted — ours is right</span>
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
    "#{row["field"]}: ours #{diff_value(row["derived"])} · filed #{diff_value(row["filed"])}"
  end

  defp diff_claim(row, context), do: "#{context} · #{diff_claim(row, nil)}"

  defp diff_target(row), do: "#{row["scope"]}|#{row["key"]}|#{row["field"]}"

  defp diff_value(nil), do: "—"
  defp diff_value(value) when is_number(value), do: Helpers.amount(value)
  defp diff_value(value), do: to_string(value)

  defp key_part(row, index) do
    row["key"] |> String.split("|") |> Enum.at(index)
  end

  # A diff key is rolled to the coarser code ("8415|18" may cover this row's
  # "84151090") — prefix plus rate decides which rendered node claims it.
  defp hsn_claim?(%{"key" => key}, row) do
    case String.split(key, "|") do
      [code, rate] ->
        String.starts_with?(to_string(row["hsn_sc"]), code) and
          rate_eq?(rate, row["rt"])

      _other ->
        false
    end
  end

  defp hsn_claims(hsn_mismatches, row) do
    Enum.filter(hsn_mismatches, &hsn_claim?(&1, row))
  end

  defp rate_eq?(a, b), do: rate_num(a) == rate_num(b)

  defp rate_num(value) when is_number(value), do: value / 1

  defp rate_num(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp rate_num(_value), do: nil

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
      :if={@row.kind != :diff and is_number(@value)}
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
    do: JS.push("select-invoice", value: %{inum: row.inum})

  defp row_click(%{kind: :diff}), do: nil

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
        Enum.flat_map(party["inv"] || [], fn inv ->
          inv_totals = invoice_totals(inv)
          row_id = contrib_id(id, inv["inum"])

          [
            %{
              kind: :contrib,
              id: row_id,
              parent: id,
              inum: inv["inum"],
              label: invoice_label(inv),
              taxable: inv_totals.taxable,
              tax: inv_totals.tax
            }
            | diff_rows(assigns.diff_by_inum[inv["inum"]] || [], id, row_id)
          ]
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

      [node | contrib_rows(contribs, id, assigns.buyers)]
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
        rate: row["rt"],
        count: length(contribs),
        taxable: row["txval"],
        tax: hsn_tax(row)
      }

      [node | contrib_rows(contribs, id, assigns.buyers)] ++
        diff_rows(hsn_claims(assigns.hsn_mismatches, row), id, id)
    end)
  end

  defp contrib_rows(contribs, parent, buyers) do
    for contrib <- contribs do
      %{
        kind: :contrib,
        id: contrib_id(parent, contrib["inum"]),
        parent: parent,
        inum: contrib["inum"],
        label: buyers[contrib["inum"]],
        taxable: contrib["txval"],
        tax: contrib["tax"]
      }
    end
  end

  defp diff_rows(rows, parent, prefix) do
    for {row, index} <- Enum.with_index(rows) do
      %{kind: :diff, id: "#{prefix}-diff-#{index}", parent: parent, diff: row}
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

  defp doc_rows(derived) do
    derived
    |> get_in(["doc_issue", "doc_det"])
    |> List.wrap()
    |> Enum.flat_map(&(&1["docs"] || []))
  end

  # The rate and HSN aggregates know their contributors by invoice number; the
  # buyer is the label that makes a row recognisable, and it comes off the
  # invoice, not off any regrouping.
  defp buyers_by_inum(invoices) do
    Map.new(invoices, &{&1["invoice_number"], &1["buyer_name"]})
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
