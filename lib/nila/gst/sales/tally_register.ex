defmodule Nila.Gst.Sales.TallyRegister do
  @moduledoc """
  Projects the latest linked Tally snapshot into an outward GST month.

  Tally is the books source and uploaded documents are evidence. A confident
  number-and-date match remains one source row (retaining the document ID and
  evidence); unmatched records and disagreements are surfaced as issues.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Clients
  alias Nila.Gst.Sales.{Invoice, Month}
  alias Nila.Gst.StateCodes
  alias Nila.Repo
  alias Nila.TallyDevices.{Company, SyncRun, SyncedVoucher}

  @sales_types ~w(sales sale salesinvoice taxinvoice)
  @tax_heads ~w(cgst sgst igst cess)

  def project(%Month{} = month) do
    companies = month |> linked_companies() |> with_completed_snapshot(month.period)
    {:ok, client} = Clients.get_client(month.org_id, month.client_id)
    documents = tag_documents(month.invoices, "sales_month_#{month.id}")

    if companies == [] do
      %{invoices: documents, issues: [], summary: document_summary(documents)}
    else
      tally_invoices = tally_invoices(month, companies, client)
      {invoices, issues} = reconcile(documents, tally_invoices)

      %{
        invoices: invoices,
        issues: issues,
        summary: source_summary(invoices, issues, companies)
      }
    end
  end

  defp linked_companies(month) do
    Repo.all(
      from c in Company,
        join: client in Nila.Clients.Client,
        on: client.active_tally_company_id == c.id,
        where: c.org_id == ^month.org_id and client.id == ^month.client_id,
        order_by: [asc: c.id]
    )
  end

  defp with_completed_snapshot(companies, period) do
    {from_date, to_date} = period_bounds(period)
    company_ids = Enum.map(companies, & &1.id)

    synced_ids =
      Repo.all(
        from r in SyncRun,
          where:
            r.company_id in ^company_ids and r.vouchers_status == "succeeded" and
              r.period_start <= ^to_date and r.period_end >= ^from_date,
          select: r.company_id,
          distinct: true
      )
      |> MapSet.new()

    Enum.filter(companies, &MapSet.member?(synced_ids, &1.id))
  end

  defp tally_invoices(month, companies, client) do
    {from_date, to_date} = period_bounds(month.period)
    company_ids = Enum.map(companies, & &1.id)
    by_id = Map.new(companies, &{&1.id, &1})

    Repo.all(
      from v in SyncedVoucher,
        where: v.company_id in ^company_ids and v.date >= ^from_date and v.date <= ^to_date,
        order_by: [asc: v.date, asc: v.id]
    )
    |> Enum.filter(&sales_voucher?/1)
    |> Enum.map(&voucher_invoice(&1, by_id[&1.company_id], client))
  end

  defp sales_voucher?(voucher) do
    voucher.voucher_type
    |> String.downcase()
    |> String.replace(~r/[^a-z]/, "")
    |> then(&(&1 in @sales_types))
  end

  defp voucher_invoice(voucher, company, client) do
    data = voucher.data || %{}
    lines = line_items(data)
    totals = line_totals(lines)

    ledger_tax =
      Enum.reduce(@tax_heads, 0.0, fn head, total ->
        total + tax_amount(List.wrap(data["ledger_entries"]), head)
      end)

    printed_tax = data["total_tax"] || if(ledger_tax > 0, do: ledger_tax, else: totals.tax)

    %{
      "id" => "tally:#{voucher.company_id}:#{voucher.identity}",
      "document_type" => document_type(data),
      "invoice_number" => voucher.voucher_number,
      "invoice_date" => voucher.date,
      "seller_name" => company.name,
      "seller_gstin" => data["seller_gstin"] || client.gstin,
      "buyer_name" => data["party_ledger_name"] || data["buyer_name"],
      "buyer_gstin" => data["party_gstin"] || data["buyer_gstin"],
      "recipient_registration" =>
        if(present?(data["party_gstin"] || data["buyer_gstin"]),
          do: "registered",
          else: data["recipient_registration"] || "unregistered"
        ),
      "place_of_supply" => normalize_pos(data["place_of_supply"]),
      "document_status" => "active",
      "supply_type" => data["supply_type"] || "taxable",
      "line_items" => lines,
      "printed_total_taxable" => data["taxable_value"] || totals.taxable,
      "printed_total_tax" => printed_tax,
      "printed_grand_total" => data["grand_total"] || totals.taxable + number(printed_tax),
      "sources" => ["tally"],
      "tally_source" => %{
        "company_id" => company.id,
        "company_name" => company.name,
        "voucher_identity" => voucher.identity,
        "voucher_type" => voucher.voucher_type,
        "voucher_number" => voucher.voucher_number,
        "last_synced_at" => DateTime.to_iso8601(voucher.updated_at)
      }
    }
  end

  defp line_items(%{"line_items" => lines}) when is_list(lines) and lines != [] do
    Enum.map(lines, fn line ->
      %{
        "description" => line["description"] || line["stock_item_name"] || "Tally sales",
        "hsn_sac" => line["hsn_sac"],
        "uom" => line["uom"],
        "quantity" => number(line["quantity"]),
        "taxable_value" => abs(number(line["taxable_value"] || line["amount"])),
        "cgst_rate" => number(line["cgst_rate"]),
        "cgst_amount" => number(line["cgst_amount"]),
        "sgst_rate" => number(line["sgst_rate"]),
        "sgst_amount" => number(line["sgst_amount"]),
        "igst_rate" => number(line["igst_rate"]),
        "igst_amount" => number(line["igst_amount"])
      }
    end)
  end

  defp line_items(data) do
    entries = List.wrap(data["ledger_entries"])
    taxable = entries |> Enum.reject(&excluded_ledger?/1) |> sum_amounts()
    taxes = Map.new(@tax_heads, &{&1, tax_amount(entries, &1)})

    [
      %{
        "description" => data["description"] || "Tally sales",
        "hsn_sac" => data["hsn_sac"],
        "uom" => data["uom"],
        "quantity" => number(data["quantity"]),
        "taxable_value" => taxable,
        "cgst_rate" => rate(taxes["cgst"], taxable),
        "cgst_amount" => taxes["cgst"],
        "sgst_rate" => rate(taxes["sgst"], taxable),
        "sgst_amount" => taxes["sgst"],
        "igst_rate" => rate(taxes["igst"], taxable),
        "igst_amount" => taxes["igst"]
      }
    ]
  end

  defp excluded_ledger?(entry) do
    name = String.downcase(to_string(entry["ledger_name"] || ""))
    party? = truthy?(entry["is_party_ledger"])
    tax? = Enum.any?(@tax_heads, &String.contains?(name, &1))
    roundoff? = String.contains?(name, "round off") or String.contains?(name, "roundoff")
    party? or tax? or roundoff?
  end

  defp tax_amount(entries, head) do
    entries
    |> Enum.filter(fn entry ->
      entry["ledger_name"] |> to_string() |> String.downcase() |> String.contains?(head)
    end)
    |> sum_amounts()
  end

  defp sum_amounts(entries), do: Enum.reduce(entries, 0.0, &(abs(number(&1["amount"])) + &2))

  defp line_totals(lines) do
    Enum.reduce(lines, %{taxable: 0.0, tax: 0.0}, fn line, totals ->
      %{
        taxable: totals.taxable + number(line["taxable_value"]),
        tax:
          totals.tax + number(line["cgst_amount"]) + number(line["sgst_amount"]) +
            number(line["igst_amount"])
      }
    end)
  end

  defp reconcile(documents, tally_invoices) do
    tally_by_key = Enum.group_by(tally_invoices, &match_key/1)
    documents_by_key = Enum.group_by(documents, &match_key/1)

    {matched_documents, issues, used_keys} =
      Enum.reduce(documents, {[], [], MapSet.new()}, fn document, {rows, issues, used} ->
        key = match_key(document)

        case {Map.get(tally_by_key, key, []), Map.get(documents_by_key, key, [])} do
          {[tally], [_document]} when not is_nil(key) ->
            merged = merge_sources(document, tally)
            mismatch = mismatch_issue(document, tally, merged)
            {[merged | rows], maybe_cons(mismatch, issues), MapSet.put(used, key)}

          _ ->
            issue = not_in_tally_issue(document)
            {[document | rows], [issue | issues], used}
        end
      end)

    tally_only =
      Enum.reject(tally_invoices, fn invoice ->
        key = match_key(invoice)
        MapSet.member?(used_keys, key)
      end)

    tally_issues = Enum.map(tally_only, &missing_document_issue/1)

    {Enum.reverse(matched_documents) ++ tally_only, Enum.reverse(issues) ++ tally_issues}
  end

  defp merge_sources(document, tally) do
    document
    |> Map.merge(Map.drop(tally, ["id", "source_pages", "source_attribution", "document"]))
    |> Map.put("id", document["id"])
    |> Map.put("sources", ["tally", "document"])
  end

  defp mismatch_issue(document, tally, merged) do
    fields =
      [
        {"buyer GSTIN", document["buyer_gstin"], tally["buyer_gstin"]},
        {"place of supply", document["place_of_supply"], tally["place_of_supply"]},
        {"taxable value", totals(document).taxable_paise, totals(tally).taxable_paise},
        {"GST", totals(document).tax_paise, totals(tally).tax_paise}
      ]
      |> Enum.filter(fn {_label, left, right} -> materially_different?(left, right) end)
      |> Enum.map(&elem(&1, 0))

    if fields == [] do
      nil
    else
      issue(
        "tally_document_mismatch",
        merged,
        "Tally and the supporting document differ on #{Enum.join(fields, ", ")}.",
        %{"fields" => fields}
      )
    end
  end

  defp not_in_tally_issue(invoice) do
    issue(
      "sales_not_in_tally",
      invoice,
      "This supporting document has no matching sales voucher in the latest Tally sync."
    )
  end

  defp missing_document_issue(invoice) do
    issue(
      "sales_document_missing",
      invoice,
      "This Tally sales voucher has no matching supporting document in Nila."
    )
  end

  defp issue(code, invoice, message, extra \\ %{}) do
    Map.merge(
      %{
        "code" => code,
        "level" => Nila.Gst.Issues.level_for(code),
        "invoice" => invoice["invoice_number"],
        "source_id" => invoice["id"],
        "message" => message
      },
      extra
    )
  end

  defp source_summary(invoices, issues, companies) do
    latest_sync =
      Repo.one(
        from r in SyncRun,
          where:
            r.company_id in ^Enum.map(companies, & &1.id) and r.vouchers_status == "succeeded",
          order_by: [desc: r.completed_at, desc: r.updated_at],
          limit: 1,
          select: coalesce(r.completed_at, r.updated_at)
      )

    %{
      total: length(invoices),
      tally: Enum.count(invoices, &("tally" in List.wrap(&1["sources"]))),
      document: Enum.count(invoices, &("document" in List.wrap(&1["sources"]))),
      matched:
        Enum.count(invoices, &(Enum.sort(List.wrap(&1["sources"])) == ["document", "tally"])),
      missing_document: Enum.count(issues, &(&1["code"] == "sales_document_missing")),
      missing_tally: Enum.count(issues, &(&1["code"] == "sales_not_in_tally")),
      conflicts: Enum.count(issues, &(&1["code"] == "tally_document_mismatch")),
      last_synced_at: latest_sync
    }
  end

  defp document_summary(documents) do
    %{
      total: length(documents),
      tally: 0,
      document: length(documents),
      matched: 0,
      missing_document: 0,
      missing_tally: 0,
      conflicts: 0,
      last_synced_at: nil
    }
  end

  defp tag_documents(invoices, namespace) do
    invoices
    |> Enum.with_index(1)
    |> Enum.map(fn {invoice, ordinal} ->
      invoice
      |> Map.put_new(
        "id",
        "#{namespace}_inv_#{String.pad_leading(to_string(ordinal), 2, "0")}"
      )
      |> Map.put_new("sources", ["document"])
    end)
  end

  defp match_key(invoice) do
    number =
      invoice["invoice_number"] |> to_string() |> String.downcase() |> String.replace(~r/\s+/, "")

    date =
      case invoice["invoice_date"] do
        %Date{} = date -> Date.to_iso8601(date)
        value when is_binary(value) -> value
        _ -> nil
      end

    if number == "" or is_nil(date), do: nil, else: {number, date}
  end

  defp totals(invoice), do: Invoice.extracted_totals_paise(invoice)

  defp materially_different?(left, right) when is_number(left) and is_number(right),
    do: abs(left - right) > 100

  defp materially_different?(left, right) do
    present?(left) and present?(right) and
      String.downcase(String.trim(to_string(left))) !=
        String.downcase(String.trim(to_string(right)))
  end

  defp document_type(data),
    do: if(truthy?(data["is_credit_note"]), do: "credit_note", else: "invoice")

  defp normalize_pos(nil), do: nil

  defp normalize_pos(value) do
    value = value |> to_string() |> String.trim()

    StateCodes.normalize_code(value) ||
      Enum.find_value(StateCodes.all(), fn name ->
        if String.downcase(name) == String.downcase(value), do: StateCodes.code_for(name)
      end) || value
  end

  defp period_bounds(<<year::binary-size(4), "-", month::binary-size(2)>>) do
    first = Date.new!(String.to_integer(year), String.to_integer(month), 1)
    {first, Date.end_of_month(first)}
  end

  defp rate(_tax, taxable) when taxable == 0, do: 0.0
  defp rate(tax, taxable), do: Float.round(tax * 100 / taxable, 2)

  defp number(value) when is_integer(value), do: value * 1.0
  defp number(value) when is_float(value), do: value

  defp number(value) when is_binary(value) do
    Nila.Gst.Money.rupee_number(value) || 0.0
  end

  defp number(_), do: 0.0
  defp present?(value), do: not (is_nil(value) or (is_binary(value) and String.trim(value) == ""))
  defp truthy?(value), do: value in [true, "Yes", "yes", "true", "1", 1]
  defp maybe_cons(nil, list), do: list
  defp maybe_cons(value, list), do: [value | list]
end
