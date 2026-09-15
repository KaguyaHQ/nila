defmodule Nila.Gst.Extraction.Sales.Normalizer do
  @moduledoc """
  Converts sales extractor artifacts into normalized invoice facts.

  Reads the extractor's `data` envelope, preserves printed evidence and
  source attribution, and resolves line amounts before filing rules consume them.
  """

  alias Nila.Gst.{Dates, InvoiceFacts, Money}
  alias Nila.Gst.LineAmounts
  alias Nila.Gst.Sales.Invoice

  @doc "Normalizes one raw sales invoice artifact into the stored invoice map."
  def normalize(%{"data" => data} = raw) when is_map(data) do
    seller = data["supplier"] || data["seller"] || %{}
    buyer = data["bill_to"] || data["buyer"] || %{}
    ship_to = normalize_party(data["ship_to"])
    document = raw["document"] || %{}
    document_type = normalize_document_type(data["document_type"], document)

    line_items =
      data
      |> Map.get("line_items", [])
      |> Enum.map(&normalize_line/1)
      |> Enum.reject(&degenerate_line?/1)

    %{
      "page" => raw["page"] || data["page"],
      "source_pages" => raw["source_pages"] || [raw["page"] || data["page"]],
      "source_attribution" => raw["source_attribution"],
      "document_type" => document_type,
      "invoice_number" =>
        normalize_document_number(value(data, ["invoice_number", "inum"]), document_type),
      "invoice_date" => normalize_invoice_date(value(data, ["invoice_date", "idt"])),
      "seller_name" => value(data, ["seller_name"]) || seller["name"],
      "seller_gstin" => value(data, ["seller_gstin"]) || seller["gstin"],
      "buyer_name" => value(data, ["buyer_name"]) || buyer["name"],
      "buyer_gstin" => blank_to_nil(value(data, ["buyer_gstin"]) || buyer["gstin"]),
      "supplier" => normalize_party(seller),
      "bill_to" => normalize_party(buyer),
      "ship_to" => ship_to,
      "recipient_registration" =>
        normalize_recipient_registration(
          data["recipient_registration"],
          value(data, ["buyer_gstin"]) || buyer["gstin"]
        ),
      "place_of_supply" =>
        Invoice.normalize_place_of_supply(
          data["printed_place_of_supply"] || data["place_of_supply"] ||
            buyer["place_of_supply"]
        ),
      "document_status" => Invoice.normalize_document_status(data["document_status"]),
      "supply_type" => Invoice.normalize_supply_type(data["supply_type"], document),
      "tax_payment" => normalize_tax_payment(data, document),
      "reverse_charge" => Map.get(data, "reverse_charge", document["reverse_charge"]),
      "line_items" => line_items,
      "printed_total_taxable" =>
        money(value(data, ["printed_total_taxable", "total_net_amount"])),
      "printed_tax_totals" => data["printed_tax_totals"],
      "tax_total_issues" => data["tax_total_issues"],
      "printed_total_tax" => money(value(data, ["printed_total_tax", "total_tax_amount"])),
      "printed_grand_total" => money(value(data, ["printed_grand_total", "total_gross_amount"])),
      "confidence" => non_empty_map(raw["confidence"]) || build_confidence(raw),
      "verification" => non_empty_map(raw["verification"]),
      "document" => document,
      "original_sale_category" => data["original_sale_category"]
    }
    |> Map.merge(
      data
      |> Map.take(
        ~w(printed_subtotal_before_discount printed_discount_amount printed_additional_charges printed_rounding_adjustment)
      )
      |> Map.new(fn {key, value} -> {key, money(value)} end)
    )
    |> Map.merge(Map.take(data, ["seller_identity"]))
    |> Invoice.resolve_line_amounts()
    |> InvoiceFacts.from_sales_map!()
    |> InvoiceFacts.to_sales_map()
  end

  # Export-payment treatment has no meaning for explicitly domestic supplies.
  # Preserve contradictory document markers so readiness can still flag them.
  defp normalize_tax_payment(data, document) do
    if data["supply_type"] in ~w(taxable nil_rated exempt non_gst) and
         document["export"] != true do
      "not_applicable"
    else
      data["tax_payment"]
    end
  end

  defp normalize_party(party) when is_map(party) do
    party
    |> Map.take(["name", "gstin", "address", "state_code"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp normalize_party(_party), do: nil

  defp normalize_line(line) do
    cgst = line["cgst"] || %{}
    sgst = line["sgst"] || %{}
    igst = line["igst"] || %{}
    cgst_rate = money(line["cgst_rate"] || cgst["rate"])
    sgst_rate = money(line["sgst_rate"] || sgst["rate"])
    igst_rate = money(line["igst_rate"] || igst["rate"])
    cgst_amount = money(line["cgst_amount"] || cgst["amount"] || line["camt"])
    sgst_amount = money(line["sgst_amount"] || sgst["amount"] || line["samt"])
    igst_amount = money(line["igst_amount"] || igst["amount"] || line["iamt"])

    # LineAmounts decides from the fields it can read on this temporary line.
    # Lift extractor aliases first, so a nested tax object is evidence during
    # the resolution pass rather than being added only to the final projection.
    amount_line =
      line
      |> Map.put("cgst_rate", cgst_rate)
      |> Map.put("sgst_rate", sgst_rate)
      |> Map.put("igst_rate", igst_rate)
      |> Map.put("cgst_amount", cgst_amount)
      |> Map.put("sgst_amount", sgst_amount)
      |> Map.put("igst_amount", igst_amount)

    amounts = LineAmounts.normalize(amount_line)

    %{
      "item_name" => blank_to_nil(line["item_name"]),
      "description" => line["description"],
      "hsn_sac" => to_string_or_nil(value(line, ["hsn_sac", "hsn_sc"])),
      "quantity" => money(value(line, ["quantity", "qty"])),
      "uom" => value(line, ["uom", "unit"]),
      "unit_price" => amounts.printed_unit_price,
      "printed_unit_price" => amounts.printed_unit_price,
      "printed_line_amount" => amounts.printed_line_amount,
      "printed_line_total" => amounts.printed_line_total,
      "printed_taxable_value" => amounts.printed_taxable_value,
      "line_amount_tax_inclusion_candidate" => amounts.line_amount_tax_inclusion_candidate,
      "line_amount_tax_inclusion" => amounts.line_amount_tax_inclusion,
      "line_amount_tax_inclusion_basis" => amounts.line_amount_tax_inclusion_basis,
      "line_amount_tax_inclusion_evidence" => amounts.line_amount_tax_inclusion_evidence,
      "line_amount_tax_inclusion_disagreement" => amounts.line_amount_tax_inclusion_disagreement,
      "taxable_value" => amounts.taxable_value,
      "taxable_value_basis" => amounts.taxable_value_basis,
      "printed_tax_components" => line["printed_tax_components"],
      "tax_component_issues" => line["tax_component_issues"],
      "cgst_rate" => cgst_rate,
      "cgst_amount" => cgst_amount,
      "sgst_rate" => sgst_rate,
      "sgst_amount" => sgst_amount,
      "igst_rate" => igst_rate,
      "igst_amount" => igst_amount
    }
  end

  defp degenerate_line?(line) do
    zeroish?(line["taxable_value"]) and zeroish?(line["quantity"]) and
      zeroish?(line["printed_line_amount"]) and zeroish?(line["printed_line_total"]) and
      zeroish?(line["cgst_amount"]) and zeroish?(line["sgst_amount"]) and
      zeroish?(line["igst_amount"])
  end

  defp zeroish?(value), do: is_nil(value) or num(value) == 0

  # Dates are parsed at the boundary, so every kind of dump carries the same
  # type downstream and a check written once covers all of them. An unparseable
  # date keeps its printed text rather than becoming nil — losing it would hide
  # the problem instead of showing it — and `unreadable_invoice_date` says so.
  defp normalize_invoice_date(nil), do: nil

  defp normalize_invoice_date(%Date{} = date), do: date

  defp normalize_invoice_date(value) do
    case Dates.parse_date(to_string(value)) do
      %Date{} = date -> date
      nil -> value
    end
  end

  defp normalize_recipient_registration(_status, gstin)
       when is_binary(gstin) and gstin != "",
       do: "registered"

  defp normalize_recipient_registration(status, _gstin)
       when status in ~w(registered unregistered unknown),
       do: status

  defp normalize_recipient_registration(_status, _gstin), do: "unknown"

  defp normalize_document_type(type, _document)
       when type in ["invoice", "credit_note", "debit_note"] do
    type
  end

  defp normalize_document_type(_type, document), do: marker_document_type(document) || "invoice"

  defp marker_document_type(%{"credit_note" => true, "debit_note" => true}), do: nil
  defp marker_document_type(%{"credit_note" => true}), do: "credit_note"
  defp marker_document_type(%{"debit_note" => true}), do: "debit_note"
  defp marker_document_type(_document), do: nil

  defp normalize_document_number(nil, _document_type), do: nil

  defp normalize_document_number(number, document_type) do
    number
    |> to_string()
    |> strip_document_label(document_type)
    |> String.trim()
    |> String.replace(~r/\s*\/\s*/, "/")
  end

  defp strip_document_label(number, "credit_note") do
    String.replace(number, ~r/^\s*(?:tax\s+)?credit\s+note\s*(?:no\.?|number)?\s*[:#-]?\s*/i, "")
  end

  defp strip_document_label(number, "debit_note") do
    String.replace(number, ~r/^\s*(?:tax\s+)?debit\s+note\s*(?:no\.?|number)?\s*[:#-]?\s*/i, "")
  end

  defp strip_document_label(number, _document_type), do: number

  defp value(map, keys), do: Enum.find_value(keys, &map[&1])

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp build_confidence(raw) do
    non_empty_map(get_in(raw, ["extract_metadata", "field_metadata", "document_metadata"])) || %{}
  end

  defp non_empty_map(value) when is_map(value) and map_size(value) > 0, do: value
  defp non_empty_map(_), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp money(value), do: Money.rupee_number(value)

  defp num(value), do: money(value) || 0
end
