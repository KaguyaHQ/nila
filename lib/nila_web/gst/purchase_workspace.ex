defmodule NilaWeb.Gst.PurchaseWorkspace do
  @moduledoc false
  alias Nila.Gst.Purchase.{
    Groups,
    ItcCases,
    Months,
    Month,
    Register,
    Resolutions,
    Review,
    Reconciliation,
    Workings
  }

  alias Nila.Gst.Filing.Signoffs

  @filters [
    {"register", "Purchase register"},
    {"gstr2b", "GSTR-2B"},
    {"needs_review", "Needs review"},
    {"all", "All"},
    {"treatment", "ITC treatment"},
    {"carried", "Carried credit"},
    {"books_only", "Books only"},
    {"2b_only", "2B only"},
    {"mismatch", "Mismatch"},
    {"possible", "Possible match"},
    {"matched", "Matched"},
    {"itc", "ITC checks"}
  ]
  def filters, do: @filters

  def normalize_filter(value),
    do: if(Enum.any?(@filters, &(elem(&1, 0) == value)), do: value, else: "needs_review")

  def load(scope, client_id, period) do
    with {:ok, _} <- Date.from_iso8601(period <> "-01"),
         {:ok, client} <- Nila.Clients.get_client(scope.current_org.id, client_id) do
      month =
        case Months.get_by_period_with_client(scope.current_org.id, client.id, period) do
          {:ok, month} ->
            month

          {:error, :not_found} ->
            %Month{
              org_id: scope.current_org.id,
              client_id: client.id,
              client: client,
              period: period
            }
        end

      workings = Resolutions.workings(month)

      if is_nil(month.id) and workings.case_lines == [] do
        {:ok,
         %{
           client: client,
           month: nil,
           workings: nil,
           review: nil,
           items: [],
           carried_cases: [],
           signed_off?: false
         }}
      else
        signoff =
          if month.id do
            case Signoffs.latest_signoff(month.id) do
              {:ok, value} -> value
              _ -> nil
            end
          end

        workings = if signoff, do: frozen_workings(signoff.snapshot, workings), else: workings
        review = Review.project(workings, month: month)
        groups = Map.new(workings.groups, &{&1.key, &1})

        items =
          Enum.map(review.all, fn item ->
            source_rows = Enum.filter(workings.rows, &(&1["id"] in item.member_ids))

            item
            |> Map.put(:bucket, bucket(item, groups[item.group_key]))
            |> Map.put(:flags, source_rows |> Enum.flat_map(&(&1["flags"] || [])) |> Enum.uniq())
            |> Map.put(:flagged?, Enum.any?(source_rows, &Register.needs_review?/1))
            |> treatment_details(workings.case_lines, period)
          end)

        {:ok,
         %{
           client: client,
           month: month,
           workings: workings,
           review: review,
           items: items,
           carried_cases: carried_cases(workings),
           signed_off?: not is_nil(signoff) or not is_nil(month.filed_at)
         }}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def filter(items, selected, query) do
    query = String.downcase(String.trim(query || ""))

    Enum.filter(items, fn item ->
      selected?(item, normalize_filter(selected)) and
        (query == "" or String.contains?(search_text(item), query))
    end)
  end

  def needs_review?(item),
    do:
      not item.resolved or item.bucket == "mismatch" or item.flagged? or
        Map.get(item, :treatment_stale?, false)

  def pairing_pending?(item), do: item.bucket == "possible" and not item.resolved

  def overview_path(client_id, period), do: "/gst/#{client_id}/#{period}/purchases"

  def source_rows(nil, _source), do: []

  def source_rows(workings, source) do
    # Baseline retains dismissed supplies and the original imported values.
    recon = workings.baseline

    if source == "register",
      do: Workings.books_invoices(recon),
      else: Workings.gstr2b_invoices(recon)
  end

  def source_tax(row) do
    tax = Enum.sum(for head <- ~w(cgst sgst igst cess), do: get_in(row, ["tax_paise", head]) || 0)
    if row["document_type"] == "credit_note", do: -abs(tax), else: tax
  end

  def overview(workings, items) do
    books = source_rows(workings, "register")
    portal = source_rows(workings, "gstr2b")

    buckets =
      for {key, label} <- [
            {"matched", "Matched"},
            {"mismatch", "Differences"},
            {"possible", "Pairing needs review"},
            {"books_only", "Only in purchases"},
            {"2b_only", "Only in GSTR-2B"}
          ] do
        grouped = Enum.filter(items, &(&1.bucket == key))
        book_rows = grouped |> Enum.flat_map(& &1.books_members) |> Enum.uniq_by(& &1["id"])

        portal_rows =
          grouped
          |> Enum.flat_map(& &1.counterparts)
          |> Enum.uniq_by(&Reconciliation.gstr2b_ref/1)

        %{
          id: key,
          label: label,
          count: length(grouped),
          books: Enum.sum(Enum.map(book_rows, &source_tax/1)),
          portal: Enum.sum(Enum.map(portal_rows, &source_tax/1))
        }
      end

    position = if workings, do: workings.itc, else: %{}

    %{
      books_count: length(books),
      portal_count: length(portal),
      books_tax: Enum.sum(Enum.map(books, &source_tax/1)),
      portal_tax: Enum.sum(Enum.map(portal, &source_tax/1)),
      buckets: buckets,
      remaining: Enum.count(items, &needs_review?/1),
      first_review: Enum.find(items, &needs_review?/1),
      claim_tax: position["current_claim_paise"] || 0,
      later_tax: position["later_paise"] || 0,
      excluded_tax: position["excluded_paise"] || 0,
      pending_tax: position["pending_paise"] || 0,
      treatment_recorded?:
        workings != nil and
          Enum.any?(workings.case_lines, &(&1.explicit_treatment? or &1.treatment == "later")),
      carried_count: length(carried_cases(workings)),
      stale_count:
        if(workings, do: Enum.count(workings.case_lines, & &1.treatment_stale?), else: 0)
    }
  end

  def label(%{bucket: "matched", flagged?: true}), do: "Matched · needs review"
  def label(item), do: item.outcome || elem(List.keyfind(@filters, item.bucket, 0), 1)
  def money(value), do: Nila.Formatters.format_money_with_paise(value || 0)

  def list_path(client_id, period, filter, q) do
    base = "/app/gst/#{client_id}/#{period}/purchases"

    if filter in ~w(register gstr2b) do
      base <>
        "/register?" <>
        URI.encode_query(%{
          source: if(filter == "gstr2b", do: "gstr2b", else: "purchases"),
          q: q || ""
        })
    else
      base <> "/review?" <> URI.encode_query(%{filter: normalize_filter(filter), q: q || ""})
    end
  end

  def review_path(client_id, period, item_id, filter, q),
    do:
      "/app/gst/#{client_id}/#{period}/purchases/review/#{URI.encode_www_form(item_id)}?" <>
        URI.encode_query(%{filter: normalize_filter(filter), q: q || ""})

  defp selected?(_, "all"), do: true
  defp selected?(item, "register"), do: item.books_members != [] and item.kind != :itc
  defp selected?(item, "gstr2b"), do: item.counterparts != [] and item.kind != :itc
  defp selected?(item, "treatment"), do: item.treatment_lines != []
  defp selected?(_, "carried"), do: false
  defp selected?(item, "needs_review"), do: needs_review?(item)
  defp selected?(item, filter), do: item.bucket == filter

  defp search_text(item) do
    docs = item.books_members ++ item.counterparts

    [
      item.vendor,
      item.invoice_number
      | Enum.flat_map(
          docs,
          &(Map.take(&1, ~w(vendor_name vendor_gstin invoice_number)) |> Map.values())
        )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp treatment_details(item, lines, period) do
    refs = Enum.map(item.counterparts, &Reconciliation.gstr2b_ref/1)

    cases =
      Enum.filter(lines, fn line ->
        sources = line.source_refs
        books = get_in(sources, ["books", period])
        portal = get_in(sources, ["gstr2b", period])

        item.kind != :itc and
          ((books != nil and books in item.member_ids) or (portal != nil and portal in refs))
      end)

    item =
      Map.merge(item, %{
        treatment_case_ids: Enum.map(cases, & &1.case_id),
        treatment_lines: cases,
        treatment_stale?: Enum.any?(cases, & &1.treatment_stale?)
      })

    case cases do
      [line] ->
        Map.merge(item, %{
          case_id: line.case_id,
          claim_tax: heads_total(line.outstanding_heads),
          selectable?:
            line.document_type in ~w(invoice debit_note) and
              heads_total(line.outstanding_heads) > 0 and line.settlement_state != "excluded",
          treatment: line.treatment,
          claimable?: line.claimable?,
          claim_block_reason: line.claim_block_reason
        })

      _ ->
        Map.merge(item, %{
          case_id: nil,
          claim_tax: 0,
          selectable?: false,
          treatment: if(cases == [], do: "undecided", else: "mixed"),
          claimable?: false,
          claim_block_reason: "Choose an individual invoice to set treatment"
        })
    end
  end

  def carried_cases(nil), do: []

  def carried_cases(workings) do
    Enum.filter(workings.case_lines, fn line ->
      line.document_type in ~w(invoice debit_note) and not line.current_books? and
        not line.current_gstr2b? and
        (heads_total(line.outstanding_heads) > 0 or line.treatment_stale?)
    end)
  end

  def filter_carried(lines, query) do
    query = String.downcase(String.trim(query || ""))

    Enum.filter(lines, fn line ->
      String.contains?(
        String.downcase(Enum.join([line.vendor, line.invoice_number, line.supplier_gstin], " ")),
        query
      )
    end)
  end

  defp heads_total(heads), do: heads |> Map.values() |> Enum.sum()

  defp bucket(%{kind: :itc}, _), do: "itc"
  defp bucket(%{kind: :gstr2b}, _), do: "2b_only"
  defp bucket(_, %{code: "value_mismatch"}), do: "mismatch"
  defp bucket(_, %{code: "matched"}), do: "matched"
  defp bucket(%{counterparts: []}, _), do: "books_only"
  defp bucket(_, _), do: "possible"

  defp frozen_workings(snapshot, fallback) do
    case snapshot["review"] do
      %{} = review ->
        recon = review["recon"] || %{}

        %{
          fallback
          | baseline: review["baseline"] || %{},
            recon: recon,
            groups: Groups.build(recon),
            decisions: review["decisions"] || %{},
            accepted_reasons: review["accepted_reasons"] || %{},
            gstr2b_decisions: review["gstr2b_decisions"] || %{},
            case_lines: ItcCases.restore_case_lines(snapshot["case_lines"] || []),
            document_cases: ItcCases.document_cases(snapshot["case_lines"] || []),
            rows: snapshot["rows"],
            summary: snapshot["summary"],
            gstr3b: snapshot["gstr3b"],
            itc: snapshot["itc"]
        }

      _ ->
        %{
          fallback
          | rows: snapshot["rows"],
            summary: snapshot["summary"],
            gstr3b: snapshot["gstr3b"],
            itc: snapshot["itc"]
        }
    end
  end
end
