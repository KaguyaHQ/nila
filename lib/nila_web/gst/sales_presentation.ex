defmodule NilaWeb.Gst.SalesPresentation do
  import Nila.Formatters, only: [format_display_date: 1]

  @moduledoc "The filing-period index and drill-downs for Sales and GSTR-1."

  alias Nila.Gst.Sales.{Gstr1, Invoice}
  alias Nila.Gst.Sales.Review.Values
  alias NilaWeb.Gst.SalesFormatting, as: Helpers

  @gstr1_table_order [
    {"b2b", "B2B — sales to registered persons"},
    {"b2cl", "B2CL — inter-state consumers"},
    {"exp", "Exports"},
    {"sez", "SEZ supplies"},
    {"b2cs", "B2C (others)"},
    {"exempt", "Exempt / non-taxable supplies"},
    {"cdnr", "Credit notes / debit notes"},
    {"advances", "Advances received / adjusted"},
    {"ecommerce", "Supplies through e-commerce operator"}
  ]

  @doc "Saved buyer lookup evidence; no lookup or refresh is performed here."
  def buyer_registration(invoice) do
    case get_in(invoice, ["taxpayer_checks", "buyer"]) do
      %{"gstin" => gstin} = facts when is_binary(gstin) ->
        if gstin == Nila.Gst.Portal.Taxpayers.normalize(invoice["buyer_gstin"]) do
          Map.new(
            ~w(gstin legal_name trade_name registration_status checked_at cancellation_date),
            fn key ->
              {key, if(facts[key] in [nil, ""], do: nil, else: facts[key])}
            end
          )
        end

      _ ->
        nil
    end
  end

  def open_issues(item) do
    item.actionable_issues
    |> Enum.filter(&(&1["status"] == "open"))
    |> Enum.map(
      &%{code: &1["code"], title: NilaWeb.Gst.SalesIssuePresentation.register_reason(&1)}
    )
    |> Enum.uniq_by(& &1.code)
  end

  @doc "Presentation of the effective return for the React sales overview."
  def summary_rows(workings, client, period) do
    review = Nila.Gst.Sales.Review.build(workings)
    ids = MapSet.new(review.needs_you, & &1.source_id)

    assigns = %{
      active_invoices: workings.active_invoices,
      derived: workings.derived,
      supplied_b2cs?: Enum.any?(Map.get(workings, :supplied_rows, []), &(&1["section"] == "b2cs"))
    }

    hsn =
      if workings.derived,
        do: Enum.flat_map(Map.values(workings.derived["hsn"] || %{}), & &1),
        else: []

    gstr1_table_rows(
      assigns,
      ids,
      hsn,
      document_rows(workings.derived),
      base_path(client, period)
    )
  end

  @doc "The existing GSTR-1 detail rows, shared with the React workspace."
  def detail_rows(workings, client, period) do
    review = Nila.Gst.Sales.Review.build(workings)
    ids = MapSet.new(review.needs_you, & &1.source_id)
    assigns = %{client: client, period: period, base: base_path(client, period), review: review}

    sections =
      for {key, label} <- @gstr1_table_order,
          key in ~w(b2b b2cl b2cs cdnr exp sez),
          into: %{} do
        invoices = Enum.filter(workings.active_invoices, &(workspace_table(&1) == key))
        {key, %{title: label, rows: invoice_rows(invoices, ids, assigns, workings)}}
      end

    Map.put(sections, "documents", %{
      title: "Documents issued",
      rows: document_rows(workings.derived)
    })
  end

  defp gstr1_table_rows(assigns, review_ids, hsn, documents, base) do
    counts = Enum.frequencies_by(assigns.active_invoices, &workspace_table/1)

    statutory =
      Enum.map(@gstr1_table_order, fn {key, label} ->
        summary? = key == "b2cs" and assigns.supplied_b2cs?

        count =
          if summary?,
            do: length((assigns.derived && assigns.derived["b2cs"]) || []),
            else: counts[key] || 0

        unresolved = count_unresolved(assigns.active_invoices, review_ids, key)
        supported = key in ~w(b2b b2cl b2cs cdnr exp sez)

        %{
          id: key,
          label: label,
          count:
            if(count == 0,
              do: "—",
              else: count_label(count, if(summary?, do: "summary", else: document_noun(key)))
            ),
          value: gstr1_table_value(assigns.derived, key, count),
          status: gstr1_table_status(count, unresolved, supported),
          variant: gstr1_table_variant(count, unresolved, supported),
          path: if(count > 0 and supported, do: base <> "/#{key}")
        }
      end)

    appendix_state =
      if(MapSet.size(review_ids) > 0, do: {"Draft", "warning"}, else: {"Prepared", "success"})

    {appendix_status, appendix_variant} = appendix_state

    statutory ++
      [
        %{
          id: "hsn",
          label: "HSN-wise summary of outward supplies",
          count: if(hsn == [], do: "—", else: "#{length(hsn)} HSN/SAC"),
          value: assigns.derived && Helpers.rupees(Values.filed_totals(assigns.derived).taxable),
          status: if(hsn == [], do: "No entries", else: appendix_status),
          variant: if(hsn == [], do: "neutral", else: appendix_variant),
          path: if(hsn != [], do: base <> "/hsn")
        },
        %{
          id: "documents",
          label: "Documents issued",
          count:
            if(documents == [],
              do: "—",
              else: count_label(Enum.sum(Enum.map(documents, & &1.net_issued)), "document")
            ),
          value: nil,
          status: if(documents == [], do: "No entries", else: appendix_status),
          variant: if(documents == [], do: "neutral", else: appendix_variant),
          path: if(documents != [], do: base <> "/documents")
        }
      ]
  end

  defp invoice_rows(invoices, review_ids, assigns, workings) do
    Enum.map(invoices, fn invoice ->
      totals =
        if workings, do: Values.filed(invoice, workings), else: Invoice.extracted_totals(invoice)

      needs_review = MapSet.member?(review_ids, invoice["id"])
      filter = Map.get(assigns, :filter, :all)
      query = if assigns[:form], do: assigns.form[:query].value || "", else: ""
      return_to = assigns.base <> "/register?" <> URI.encode_query(%{q: query, filter: filter})

      item =
        if assigns[:review], do: Enum.find(assigns.review.all, &(&1.source_id == invoice["id"]))

      open_issues =
        if item, do: Enum.filter(item.actionable_issues, &(&1["status"] == "open")), else: []

      reason =
        if needs_review && open_issues != [],
          do: NilaWeb.Gst.SalesIssuePresentation.register_reason(hd(open_issues))

      %{
        id: invoice["id"] || invoice["invoice_number"],
        number: invoice["invoice_number"] || "—",
        date: format_display_date(invoice["invoice_date"]),
        buyer: invoice["buyer_name"] || "—",
        treatment: invoice_treatment(invoice),
        taxable: Helpers.rupees(totals && totals.taxable),
        tax: Helpers.rupees(totals && totals.tax),
        status: if(needs_review, do: "Needs review", else: "Ready"),
        variant: if(needs_review, do: "warning", else: "success"),
        reason: reason,
        reason_detail: Enum.find_value(open_issues, & &1["message"]),
        path:
          review_path(
            assigns.client,
            assigns.period,
            invoice["id"],
            case filter do
              :review_cases -> :needs_you
              :no_open_checks -> :ready
              _ -> :all
            end,
            return_to
          )
      }
    end)
  end

  defp count_unresolved(invoices, review_ids, key),
    do:
      Enum.count(
        invoices,
        &(workspace_table(&1) == key and MapSet.member?(review_ids, &1["id"]))
      )

  defp gstr1_table_value(_derived, _key, 0), do: nil
  defp gstr1_table_value(nil, _key, _count), do: nil

  defp gstr1_table_value(derived, key, _count),
    do: Helpers.rupees(section_totals(derived, key).taxable)

  defp gstr1_table_status(0, _unresolved, _supported), do: "No entries"

  defp gstr1_table_status(_count, unresolved, _supported) when unresolved > 0, do: "Draft"

  defp gstr1_table_status(_count, _unresolved, true), do: "Prepared"
  defp gstr1_table_status(_count, _unresolved, false), do: "Not supported"

  defp gstr1_table_variant(0, _unresolved, _supported), do: "neutral"
  defp gstr1_table_variant(_count, unresolved, _supported) when unresolved > 0, do: "warning"
  defp gstr1_table_variant(_count, _unresolved, true), do: "success"
  defp gstr1_table_variant(_count, _unresolved, false), do: "error"

  defp section_totals(derived, section) when section in ["sez", "b2b"] do
    groups =
      for group <- derived["b2b"] || [] do
        Map.update!(
          group,
          "inv",
          &Enum.filter(&1, fn inv -> inv["inv_typ"] in ["SEWP", "SEWOP"] == (section == "sez") end)
        )
      end

    section_totals(Map.put(derived, "b2b", groups), "registered")
  end

  defp section_totals(derived, section) do
    section = if section == "registered", do: "b2b", else: section

    Enum.reduce(~w(b2b b2cs b2cl cdnr cdnur nil exp), derived, fn key, acc ->
      if key == section, do: acc, else: Map.put(acc, key, if(key == "nil", do: %{}, else: []))
    end)
    |> Values.filed_totals()
  end

  defp document_rows(nil), do: []

  defp document_rows(derived) do
    derived
    |> get_in(["doc_issue", "doc_det"])
    |> List.wrap()
    |> Enum.flat_map(fn group ->
      group
      |> Map.get("docs", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {series, index} ->
        %{
          id: "#{group["doc_num"]}-#{index}",
          kind: document_kind(group["doc_num"]),
          from: series["from"],
          to: series["to"],
          total: series["totnum"],
          cancelled: series["cancel"],
          net_issued: series["net_issue"]
        }
      end)
    end)
  end

  defp document_kind(1), do: "Tax invoices"
  defp document_kind(4), do: "Debit notes"
  defp document_kind(5), do: "Credit notes"
  defp document_kind(number), do: "Document type #{number}"

  defp document_noun("cdnr"), do: "note"
  defp document_noun(_key), do: "invoice"

  defp workspace_table(invoice) do
    if Gstr1.filing_table(invoice) == "b2b" and invoice["supply_type"] == "sez",
      do: "sez",
      else: Gstr1.filing_table(invoice)
  end

  defp invoice_treatment(invoice) do
    cond do
      is_nil(Gstr1.filing_table(invoice)) ->
        "Held out"

      Invoice.reverse_charge?(invoice) ->
        "B2B · reverse charge"

      Invoice.zero_rated?(invoice) ->
        treatment_label(workspace_table(invoice)) <>
          if(Invoice.without_payment?(invoice), do: " · LUT/bond", else: " · with IGST")

      true ->
        treatment_label(workspace_table(invoice))
    end
  end

  defp treatment_label("exp"), do: "Export"
  defp treatment_label("sez"), do: "SEZ"
  defp treatment_label("b2b"), do: "B2B"
  defp treatment_label("b2cl"), do: "B2CL"
  defp treatment_label("b2cs"), do: "B2C"
  defp treatment_label("cdnr"), do: "Credit/debit note"
  defp treatment_label(_table), do: "Held out"

  defp review_path(client, period, source_id, scope, return_to) do
    query =
      URI.encode_query(%{"item" => source_id, "scope" => scope, "return_to" => return_to})

    "/gst/#{client.id}/#{period}/sales/invoices/#{URI.encode_www_form(source_id)}?#{query}"
  end

  defp base_path(client, period), do: "/gst/#{client.id}/#{period}/sales"

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(count, "summary"), do: "#{count} summaries"
  defp count_label(count, "batch"), do: "#{count} batches"
  defp count_label(count, noun), do: "#{count} #{noun}s"
end
