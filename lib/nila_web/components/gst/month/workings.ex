defmodule NilaWeb.Components.Gst.Month.Workings do
  use NilaWeb, :html

  @moduledoc """
  The GSTR-1 workings body: the derived return rendered in the working-sheet
  shape a CA already reads — B2B party-wise, rate summary, HSN, documents
  issued.

  Renders the materialized projection (`derived_gstr1` out of
  `Nila.Gst.Sales.Workings.materialize/4`, or a sign-off snapshot) — never the
  pristine month. Every aggregate opens to the invoices that built it, each
  linking into the invoice modal, and the contributor keys come from the same
  derivation functions that build the portal JSON (`Gstr1.hsn_summary/1`,
  `Gstr1.rate_summary/1`) — this module never regroups anything, so a number
  here and the JSON beside it cannot disagree. Empty subsections are omitted
  outright: a month with no B2B shows no B2B heading.
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

  def workings_body(assigns) do
    assigns =
      assigns
      |> assign(:b2b, assigns.derived["b2b"] || [])
      |> assign(:rates, Gstr1.rate_summary(assigns.derived))
      |> assign(:hsn, Gstr1.hsn_summary(assigns.invoices))
      |> assign(:docs, doc_rows(assigns.derived))
      |> assign(:names, names_by_gstin(assigns.invoices))
      |> assign_diff()

    ~H"""
    <div id="gstr1-workings" class="space-y-4">
      <p
        :if={@diff}
        id="gstr1-diff-summary"
        class="text-base-content/70 text-small flex items-center gap-2"
      >
        <.icon
          name={
            if @mismatches == [],
              do: "hero-check-circle-mini",
              else: "hero-exclamation-triangle-mini"
          }
          class={["size-4 shrink-0", (@mismatches == [] && "text-success") || "text-warning"]}
        />
        {diff_summary_line(@diff, @mismatches)}
      </p>

      <div :if={@b2b != []} id="gstr1-workings-b2b" class="space-y-2">
        <div class="text-base-content/60 text-label font-medium uppercase">B2B — party-wise</div>
        <details
          :for={party <- @b2b}
          id={party_node_id(party["ctin"])}
          class={[
            "border-base-300 group/party rounded-box border",
            ripple_class(@rippled, @ripple_seq, party_node_id(party["ctin"]))
          ]}
        >
          <summary class="hover:bg-base-200/40 text-small flex cursor-pointer list-none items-center gap-3 px-4 py-2.5">
            <span class="min-w-0 flex-1 truncate">
              <span class="text-base-content font-medium">{party_name(@names, party)}</span>
              <span
                :if={@names[party["ctin"]] && party["ctin"]}
                class="text-base-content/50 text-fine ml-2 font-mono"
              >
                {party["ctin"]}
              </span>
            </span>
            <span class="text-base-content/60 shrink-0">{count_label(party["inv"], "invoice")}</span>
            <span class="text-base-content shrink-0 font-medium">
              {Helpers.rupees(party_totals(party).taxable)}
            </span>
            <.icon
              name="hero-chevron-right-mini"
              class="text-base-content/40 size-4 shrink-0 transition-transform group-open/party:rotate-90"
            />
          </summary>
          <div class="border-base-300 text-small space-y-1 border-t px-4 py-2.5">
            <div :for={inv <- party["inv"]} class="space-y-1">
              <div class="flex flex-wrap items-baseline gap-x-3 gap-y-0.5">
                <.invoice_link inum={inv["inum"]} />
                <span class="text-base-content/60">{inv["idt"]}</span>
                <span class="text-base-content/70 min-w-0 flex-1">{bucket_label(inv)}</span>
                <span class="text-base-content/80">{Helpers.rupees(inv["val"])}</span>
              </div>
              <.diff_row
                :for={row <- @diff_by_inum[inv["inum"]] || []}
                row={row}
                accepted={@accepted}
                locked={@locked}
                class="pl-4"
              />
            </div>
            <div class="border-base-300 text-base-content/60 mt-1.5 flex justify-between gap-3 border-t pt-1.5">
              <span>party total</span>
              <span>
                {Helpers.amount(party_totals(party).taxable)} taxable + {Helpers.amount(
                  party_totals(party).tax
                )} tax
              </span>
            </div>
          </div>
        </details>
      </div>

      <div :if={@rates != []} id="gstr1-workings-rates" class="space-y-2">
        <div class="text-base-content/60 text-label font-medium uppercase">Rate summary</div>
        <details
          :for={bucket <- @rates}
          id={rate_node_id(bucket["rate"])}
          class={[
            "border-base-300 group/rate rounded-box border",
            ripple_class(@rippled, @ripple_seq, rate_node_id(bucket["rate"]))
          ]}
        >
          <summary class="hover:bg-base-200/40 text-small flex cursor-pointer list-none items-center gap-3 px-4 py-2.5">
            <span class="text-base-content w-12 shrink-0 font-medium">
              {Helpers.percent(bucket["rate"])}
            </span>
            <span class="text-base-content/70 min-w-0 flex-1">
              {Helpers.amount(bucket["taxable"])} taxable + {Helpers.amount(bucket["tax"])} tax
            </span>
            <span class="text-base-content/60 shrink-0">
              {count_label(bucket["inums"], "invoice")}
            </span>
            <.icon
              name="hero-chevron-right-mini"
              class="text-base-content/40 size-4 shrink-0 transition-transform group-open/rate:rotate-90"
            />
          </summary>
          <div class="border-base-300 border-t px-4 py-2.5">
            <.contributors inums={bucket["inums"]} />
          </div>
        </details>
      </div>

      <div :if={@hsn != []} id="gstr1-workings-hsn" class="space-y-2">
        <div class="text-base-content/60 text-label font-medium uppercase">HSN summary</div>
        <details
          :for={row <- @hsn}
          id={hsn_node_id(row)}
          class={[
            "border-base-300 group/hsn rounded-box border",
            ripple_class(@rippled, @ripple_seq, hsn_node_id(row))
          ]}
        >
          <summary class="hover:bg-base-200/40 text-small flex cursor-pointer list-none items-center gap-3 px-4 py-2.5">
            <span class="text-base-content w-24 shrink-0 font-mono font-medium">
              {row["hsn_sc"] || "—"}
            </span>
            <span class="text-base-content/60 w-12 shrink-0">{Helpers.percent(row["rt"])}</span>
            <span class="text-base-content/70 min-w-0 flex-1">
              {Helpers.amount(row["txval"])} taxable + {Helpers.amount(hsn_tax(row))} tax
            </span>
            <.icon
              name="hero-chevron-right-mini"
              class="text-base-content/40 size-4 shrink-0 transition-transform group-open/hsn:rotate-90"
            />
          </summary>
          <div class="border-base-300 space-y-1 border-t px-4 py-2.5">
            <.contributors inums={row["inums"]} />
            <.diff_row
              :for={diff <- hsn_claims(@hsn_mismatches, row)}
              row={diff}
              accepted={@accepted}
              locked={@locked}
            />
          </div>
        </details>
      </div>

      <div :if={@docs != []} id="gstr1-workings-docs" class="space-y-2">
        <div class="text-base-content/60 text-label font-medium uppercase">Documents issued</div>
        <div
          :for={doc <- @docs}
          class="border-base-300 rounded-box text-base-content/70 text-small border px-4 py-2.5"
        >
          {doc["from"]} – {doc["to"]} · {doc["totnum"]} numbers · {doc["cancel"]} cancelled · {doc[
            "net_issue"
          ]} issued
        </div>
        <.diff_row
          :for={row <- @doc_mismatches}
          row={row}
          accepted={@accepted}
          locked={@locked}
        />
      </div>

      <div :if={@unclaimed != []} id="gstr1-diff-unclaimed" class="space-y-2">
        <div class="text-base-content/60 text-label font-medium uppercase">
          Only one side holds these
        </div>
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

  defp diff_summary_line(diff, []) do
    "Against the filed return: all #{length(diff)} compared fields match"
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
    <div class={["text-small flex flex-wrap items-center gap-x-2 gap-y-1", @class]}>
      <.icon
        name="hero-exclamation-triangle-mini"
        class={[
          "size-4 shrink-0",
          (MapSet.member?(@accepted, @target) && "text-base-content/40") || "text-warning"
        ]}
      />
      <span class="text-base-content/70">
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

  defp party_node_id(ctin), do: "gstr1-workings-party-#{ctin || "nogstin"}"

  defp rate_node_id(rate), do: "gstr1-workings-rate-#{trim_rate(rate)}"

  defp hsn_node_id(row),
    do: "gstr1-workings-hsn-#{row["hsn_sc"] || "none"}-#{trim_rate(row["rt"])}"

  defp trim_rate(rate) when is_number(rate) do
    if rate == trunc(rate), do: trunc(rate), else: rate
  end

  defp trim_rate(rate), do: rate

  attr :inums, :list, required: true

  defp contributors(assigns) do
    ~H"""
    <div class="text-small flex flex-wrap gap-x-3 gap-y-1">
      <.invoice_link :for={inum <- @inums} inum={inum} />
    </div>
    """
  end

  attr :inum, :string, required: true

  # Level 2 → level 3 of the pyramid: every contributor opens the invoice's
  # modal, where the scan and the arithmetic sit side by side.
  defp invoice_link(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select-invoice"
      phx-value-inum={@inum}
      class="text-primary font-mono hover:underline"
    >
      {@inum}
    </button>
    """
  end

  # Display sums of the very numbers the portal receives — reading the derived
  # JSON, never re-deriving from the invoices.
  defp party_totals(party) do
    dets = for inv <- party["inv"] || [], itm <- inv["itms"] || [], do: itm["itm_det"] || %{}

    %{
      taxable: dets |> Enum.map(&(&1["txval"] || 0)) |> Enum.sum(),
      tax:
        dets
        |> Enum.map(&((&1["camt"] || 0) + (&1["samt"] || 0) + (&1["iamt"] || 0)))
        |> Enum.sum()
    }
  end

  defp party_name(names, party) do
    names[party["ctin"]] || party["ctin"] || "No GSTIN"
  end

  defp bucket_label(inv) do
    Enum.map_join(inv["itms"] || [], " · ", fn itm ->
      det = itm["itm_det"] || %{}
      "#{Helpers.percent(det["rt"])} on #{Helpers.amount(det["txval"])}"
    end)
  end

  defp hsn_tax(row), do: (row["camt"] || 0) + (row["samt"] || 0) + (row["iamt"] || 0)

  defp doc_rows(derived) do
    derived
    |> get_in(["doc_issue", "doc_det"])
    |> List.wrap()
    |> Enum.flat_map(&(&1["docs"] || []))
  end

  defp count_label(list, word) do
    count = length(list || [])
    "#{count} #{if count == 1, do: word, else: word <> "s"}"
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
