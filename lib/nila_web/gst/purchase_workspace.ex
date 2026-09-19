defmodule NilaWeb.Gst.PurchaseWorkspace do
  @moduledoc false
  alias Nila.Gst.Purchase.{
    Groups,
    ItcCases,
    Months,
    Register,
    Resolutions,
    Review,
    Reconciliation
  }

  alias Nila.Gst.Filing.Signoffs

  @filters [
    {"needs_review", "Needs review"},
    {"all", "All"},
    {"not_claiming", "Not claiming"},
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
      case Months.get_by_period_with_client(scope.current_org.id, client.id, period) do
        {:ok, month} ->
          signoff =
            case Signoffs.latest_signoff(month.id) do
              {:ok, value} -> value
              _ -> nil
            end

          workings = Resolutions.workings(month)
          workings = if signoff, do: frozen_workings(signoff.snapshot, workings), else: workings
          review = Review.project(workings, month: month)
          groups = Map.new(workings.groups, &{&1.key, &1})

          items =
            Enum.map(review.all, fn item ->
              source_rows = Enum.filter(workings.rows, &(&1["id"] in item.member_ids))

              item
              |> Map.put(:bucket, bucket(item, groups[item.group_key]))
              |> Map.put(
                :flags,
                source_rows |> Enum.flat_map(&(&1["flags"] || [])) |> Enum.uniq()
              )
              |> Map.put(:flagged?, Enum.any?(source_rows, &Register.needs_review?/1))
              |> claim_details(workings.case_lines, period)
            end)

          {:ok,
           %{
             client: client,
             month: month,
             workings: workings,
             review: review,
             items: items,
             signed_off?: not is_nil(signoff) or not is_nil(month.filed_at)
           }}

        {:error, :not_found} ->
          {:ok,
           %{
             client: client,
             month: nil,
             workings: nil,
             review: nil,
             items: [],
             signed_off?: false
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

  def needs_review?(item), do: not item.resolved or item.bucket == "mismatch" or item.flagged?
  def label(%{bucket: "matched", flagged?: true}), do: "Matched · needs review"
  def label(item), do: item.outcome || elem(List.keyfind(@filters, item.bucket, 0), 1)
  def money(value), do: Nila.Formatters.format_money_with_paise(value || 0)

  def list_path(client_id, period, filter, q),
    do:
      "/gst/#{client_id}/#{period}/purchases?" <>
        URI.encode_query(%{filter: normalize_filter(filter), q: q || ""})

  def review_path(client_id, period, item_id, filter, q),
    do:
      "/gst/#{client_id}/#{period}/purchases/invoices/#{URI.encode_www_form(item_id)}?" <>
        URI.encode_query(%{filter: normalize_filter(filter), q: q || ""})

  defp selected?(_, "all"), do: true
  defp selected?(item, "not_claiming"), do: item.claim_state == "not_claiming"
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

  defp claim_details(item, lines, period) do
    refs = Enum.map(item.counterparts, &Reconciliation.gstr2b_ref/1)

    cases =
      Enum.filter(lines, fn line ->
        sources = line.source_refs
        books = get_in(sources, ["books", period])
        portal = get_in(sources, ["gstr2b", period])

        item.kind != :itc and
          ((books != nil and books in item.member_ids) or (portal != nil and portal in refs))
      end)

    exclusions = Enum.filter(cases, &(Map.get(&1, :claim_state) == "not_claiming"))
    item = Map.put(item, :claim_exclusions, exclusions)

    case cases do
      [line] ->
        Map.merge(item, %{
          case_id: line.case_id,
          claim_tax: line.tax_paise,
          selectable?:
            line.document_type in ~w(invoice debit_note) and line.tax_paise > 0 and
              line.settlement_state != "excluded",
          claim_state: Map.get(line, :claim_state),
          claim_reason: Map.get(line, :claim_reason)
        })

      _ ->
        Map.merge(item, %{
          case_id: nil,
          claim_tax: 0,
          selectable?: false,
          claim_state: if(exclusions != [], do: "not_claiming"),
          claim_reason:
            Enum.map_join(exclusions, "; ", &"#{&1.invoice_number}: #{&1.claim_reason}")
        })
    end
  end

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
