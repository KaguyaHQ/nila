defmodule NilaWeb.Gst.SalesIssuePresentation do
  @moduledoc "Builds bounded, human-facing copy from structured sales readiness issues."

  alias Nila.Formatters
  @printed_total_codes ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch)
  @tax_calculation_codes ~w(
    line_arithmetic cgst_sgst_unequal bucket_tax_mismatch lopsided_tax_split
  )
  @rate_codes ~w(
    hsn_multiple_rates statutory_rate_mismatch statutory_rate_review rate_history_conflict
  )
  @capability_codes ~w(
    export_supply_unsupported sez_supply_unsupported nil_rated_supply_unsupported
    exempt_supply_unsupported non_gst_supply_unsupported outward_reverse_charge_unsupported
    cdnur_unsupported cancelled_document_unsupported amendment_document_unsupported
  )
  @fact_codes ~w(
    invalid_gstin recipient_registration_conflict unknown_recipient_registration
    unreadable_invoice_date missing_invoice_number implausible_invoice_number duplicate_invoice_number
  )
  @allocation_codes ~w(
    printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch mixed_tax_heads
  )

  def for_invoice(invoice, issues) when is_map(invoice) and is_list(issues) do
    issues = Enum.filter(issues, &Nila.Gst.Sales.Tally.Readiness.relevant_invoice_issue?/1)

    items =
      []
      |> add_capability_items(issues)
      |> add_mixed_tax_item(issues)
      |> add_printed_total_item(issues)
      |> add_tax_calculation_item(issues)
      |> add_hsn_items(issues)
      |> add_rate_item(issues)
      |> add_identity_items(invoice, issues)
      |> add_document_items(issues)
      |> add_unknown_item(issues)

    items = attach_context(items, issues)

    %{
      summary: summary(items),
      details: details(items),
      items: items
    }
  end

  defp attach_context(items, issues) do
    Enum.map(items, fn item ->
      related = Enum.filter(issues, &(&1["code"] in item.codes))
      lines = related |> Enum.flat_map(&List.wrap(&1["lines"])) |> Enum.uniq() |> Enum.sort()

      target =
        cond do
          Enum.any?(item.codes, &(&1 in @fact_codes)) -> :facts
          lines != [] -> :lines
          Enum.any?(item.codes, &(&1 in @allocation_codes)) -> :allocations
          true -> :global
        end

      Map.merge(item, %{target: target, lines: lines})
    end)
  end

  defp add_capability_items(items, issues) do
    items
    |> maybe_add(issue?(issues, "cess_unsupported"), fn ->
      issue = find(issues, "cess_unsupported")
      codes = issue["hsn_codes"] || []
      suffix = if codes == [], do: "", else: " Affected HSN/SAC: #{Enum.join(codes, ", ")}."

      item(
        "unsupported voucher treatment",
        "This invoice may include compensation cess, which Nila cannot send.",
        "Nila’s current sales outputs do not carry compensation cess.#{suffix}",
        ["cess_unsupported"]
      )
    end)
    |> maybe_add(
      issue?(issues, "tally_export_failed") and
        Enum.all?(issues, &(&1["code"] == "tally_export_failed")),
      fn ->
        item(
          "Tally export",
          "Nila could not prepare this invoice as a Tally voucher.",
          "The structured checks passed, but voucher generation still failed.",
          ["tally_export_failed"]
        )
      end
    )
    |> then(fn current ->
      Enum.reduce(@capability_codes, current, fn code, acc ->
        maybe_add(acc, issue?(issues, code), fn -> capability_item(code) end)
      end)
    end)
  end

  defp capability_item("export_supply_unsupported"),
    do:
      item(
        "unsupported voucher treatment",
        "Nila cannot send this export treatment to Tally.",
        nil,
        ["export_supply_unsupported"]
      )

  defp capability_item("sez_supply_unsupported"),
    do:
      item(
        "unsupported voucher treatment",
        "Nila cannot send this SEZ treatment to Tally.",
        nil,
        ["sez_supply_unsupported"]
      )

  defp capability_item("outward_reverse_charge_unsupported"),
    do:
      item(
        "unsupported voucher treatment",
        "Nila cannot send this outward reverse-charge treatment to Tally.",
        nil,
        ["outward_reverse_charge_unsupported"]
      )

  defp capability_item("cancelled_document_unsupported"),
    do:
      item(
        "unsupported voucher treatment",
        "A cancelled invoice must not be created as a new Tally voucher.",
        nil,
        ["cancelled_document_unsupported"]
      )

  defp capability_item("amendment_document_unsupported"),
    do:
      item(
        "unsupported voucher treatment",
        "Nila cannot link this amendment to its original Tally voucher.",
        nil,
        ["amendment_document_unsupported"]
      )

  defp capability_item(code) do
    item(
      "unsupported voucher treatment",
      "Nila cannot send this invoice treatment to Tally.",
      nil,
      [code]
    )
  end

  defp add_mixed_tax_item(items, issues) do
    maybe_add(items, issue?(issues, "mixed_tax_heads"), fn ->
      issue = find(issues, "mixed_tax_heads")

      detail =
        if is_number(issue["igst"]) and is_number(issue["split_tax"]) do
          "Invoice carries #{rupees(issue["igst"])} IGST and #{rupees(issue["split_tax"])} CGST/SGST."
        end

      item(
        "tax treatment",
        "Invoice uses both IGST and CGST/SGST; one tax treatment must be corrected.",
        detail,
        ["mixed_tax_heads"]
      )
    end)
  end

  defp add_printed_total_item(items, issues) do
    family = matching(issues, @printed_total_codes)

    maybe_add(items, family != [], fn ->
      detail =
        family
        |> Enum.flat_map(&printed_total_details/1)
        |> Enum.uniq()
        |> Enum.join(" ")
        |> blank_to_nil()

      item(
        "invoice totals",
        "Extracted line totals don’t match the printed invoice totals.",
        detail,
        Enum.map(family, & &1["code"])
      )
    end)
  end

  defp add_tax_calculation_item(items, issues) do
    family = tax_calculation_family(issues)

    maybe_add(items, family != [], fn ->
      item(
        "tax calculations",
        "Tax calculations need review.",
        affected_lines_sentence(family),
        Enum.map(family, & &1["code"])
      )
    end)
  end

  defp tax_calculation_family(issues) do
    matching(issues, @tax_calculation_codes)
  end

  defp add_hsn_items(items, issues) do
    items
    |> maybe_add(issue?(issues, "missing_hsn_sac"), fn ->
      issue = find(issues, "missing_hsn_sac")
      summary = missing_hsn_sentence([issue])
      item("HSN/SAC", summary, nil, ["missing_hsn_sac"])
    end)
    |> maybe_add(issue?(issues, "incomplete_hsn_sac"), fn ->
      issue = find(issues, "incomplete_hsn_sac")

      item(
        "HSN/SAC",
        "Some HSN/SAC codes are incomplete.",
        code_line_detail(issue),
        ["incomplete_hsn_sac"]
      )
    end)
    |> maybe_add(issue?(issues, "invalid_hsn_sac"), fn ->
      issue = find(issues, "invalid_hsn_sac")

      item(
        "HSN/SAC",
        "Some HSN/SAC codes are not in the active GST directory.",
        code_line_detail(issue),
        ["invalid_hsn_sac"]
      )
    end)
    |> maybe_add(issue?(issues, "hsn_inferred_code"), fn ->
      issue = find(issues, "hsn_inferred_code")

      item(
        "HSN/SAC",
        "Inferred HSN/SAC codes need confirmation.",
        code_line_detail(issue),
        ["hsn_inferred_code"]
      )
    end)
    |> maybe_add(issue?(issues, "missing_uom"), fn ->
      issue = find(issues, "missing_uom")

      item(
        "item units",
        "Unit of measurement is missing from B2C item lines.",
        affected_lines_sentence([issue]),
        ["missing_uom"]
      )
    end)
  end

  defp add_rate_item(items, issues) do
    family = matching(issues, @rate_codes)

    maybe_add(items, family != [], fn ->
      codes =
        family |> Enum.flat_map(&List.wrap(&1["hsn_codes"] || &1["hsn_code"])) |> Enum.uniq()

      rates = family |> Enum.flat_map(&List.wrap(&1["hsn_rates"])) |> Enum.uniq() |> Enum.sort()

      detail =
        [
          codes != [] && "HSN/SAC: #{Enum.join(codes, ", ")}.",
          rates != [] && "Rates in evidence: #{Enum.map_join(rates, ", ", &rate/1)}."
        ]
        |> Enum.reject(&(&1 in [nil, false]))
        |> Enum.join(" ")
        |> blank_to_nil()

      item(
        "GST rates",
        "HSN/SAC and GST rates need review.",
        detail,
        Enum.map(family, & &1["code"])
      )
    end)
  end

  defp add_identity_items(items, _invoice, issues) do
    items
    |> maybe_add(issue?(issues, "invalid_gstin"), fn ->
      fields = issues |> matching(["invalid_gstin"]) |> Enum.flat_map(&List.wrap(&1["fields"]))

      label =
        case {"seller_gstin" in fields, "buyer_gstin" in fields} do
          {true, true} -> "Seller and buyer GSTINs need correction."
          {true, false} -> "Seller GSTIN needs correction."
          {false, true} -> "Buyer GSTIN needs correction."
          _ -> "A GSTIN needs correction."
        end

      item("GSTIN", label, nil, ["invalid_gstin"])
    end)
    |> maybe_add(issue?(issues, "recipient_registration_conflict"), fn ->
      item(
        "recipient registration",
        "Recipient registration conflicts with the buyer GSTIN.",
        nil,
        ["recipient_registration_conflict"]
      )
    end)
    |> maybe_add(issue?(issues, "unknown_recipient_registration"), fn ->
      item(
        "recipient registration",
        "Recipient registration needs classification.",
        nil,
        ["unknown_recipient_registration"]
      )
    end)
  end

  defp add_document_items(items, issues) do
    mappings = [
      {"missing_taxable_value", "taxable values", "Taxable value is missing from invoice lines."},
      {"unreadable_amount", "invoice amounts", "An invoice amount could not be read."},
      {"ungrounded_extracted_value", "source evidence",
       "An extracted value was not found on the source invoice."},
      {"furniture_row_with_values", "invoice rows",
       "A non-item row contains taxable or tax values."},
      {"zero_value_row", "invoice rows", "A zero-value invoice row needs review."},
      {"unreadable_invoice_date", "invoice date", "Invoice date needs correction."},
      {"missing_invoice_number", "invoice number", "Invoice number is missing."},
      {"implausible_invoice_number", "invoice number", "Invoice number needs correction."},
      {"invalid_document_type", "document type", "Document type is invalid."},
      {"document_type_conflict", "document type",
       "Document type conflicts with the source invoice."},
      {"unknown_document_status", "document status", "Document status needs classification."},
      {"unknown_supply_type", "supply type", "Supply type needs classification."},
      {"duplicate_invoice_number", "duplicate invoice",
       "This invoice number appears on more than one source document."}
    ]

    Enum.reduce(mappings, items, fn {code, topic, summary}, acc ->
      maybe_add(acc, issue?(issues, code), fn ->
        issue = find(issues, code)
        item(topic, summary, affected_lines_sentence([issue]), [code])
      end)
    end)
  end

  defp add_unknown_item(items, issues) do
    covered =
      items
      |> Enum.flat_map(& &1.codes)
      |> MapSet.new()
      |> MapSet.union(collapsed_issue_codes(issues))

    unknown = Enum.reject(issues, &MapSet.member?(covered, &1["code"]))

    maybe_add(items, unknown != [], fn ->
      item(
        "invoice details",
        "Invoice needs review before Tally.",
        nil,
        Enum.map(unknown, & &1["code"])
      )
    end)
  end

  defp collapsed_issue_codes(issues) do
    codes =
      if issue?(issues, "tally_export_failed") and
           Enum.any?(issues, &(&1["code"] != "tally_export_failed")),
         do: ["tally_export_failed"],
         else: []

    MapSet.new(codes)
  end

  defp summary([]), do: "Invoice needs review before Tally."
  defp summary([item]), do: item.summary

  defp summary(items) do
    topics = items |> Enum.map(& &1.topic) |> Enum.uniq()
    topics |> human_join() |> capitalize_first() |> Kernel.<>(" need review.")
  end

  defp details([%{detail: detail}]) when is_binary(detail), do: [detail]
  defp details([_item]), do: []

  defp details(items) do
    Enum.map(items, fn item -> item.detail || item.summary end)
  end

  defp item(topic, summary, detail, codes),
    do: %{topic: topic, summary: summary, detail: detail, codes: codes}

  defp maybe_add(items, false, _builder), do: items
  defp maybe_add(items, true, builder), do: items ++ [builder.()]

  defp matching(issues, codes), do: Enum.filter(issues, &(&1["code"] in codes))
  defp issue?(issues, code), do: Enum.any?(issues, &(&1["code"] == code))
  defp find(issues, code), do: Enum.find(issues, &(&1["code"] == code))

  defp affected_lines_sentence(issues) do
    case affected_line_count(issues) do
      0 -> nil
      1 -> "1 line needs review."
      count -> "#{count} lines need review."
    end
  end

  defp affected_line_count(issues) do
    issues
    |> Enum.flat_map(&List.wrap(&1["lines"]))
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> length()
  end

  defp missing_hsn_sentence(issues) do
    case affected_line_count(issues) do
      0 -> "HSN/SAC codes are missing."
      1 -> "HSN/SAC is missing on 1 line."
      count -> "HSN/SAC codes are missing on #{count} lines."
    end
  end

  defp code_line_detail(issue) do
    codes = List.wrap(issue["hsn_codes"] || issue["hsn_code"])
    lines = List.wrap(issue["lines"])

    [
      codes != [] && "HSN/SAC: #{Enum.join(codes, ", ")}.",
      lines != [] && "Lines: #{Enum.join(lines, ", ")}."
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" ")
    |> blank_to_nil()
  end

  defp printed_total_details(%{"code" => code} = issue) do
    component =
      case code do
        "printed_taxable_mismatch" -> amount_difference("taxable", issue["operands"])
        "printed_tax_mismatch" -> amount_difference("tax", issue["operands"])
        "grand_total_mismatch" -> grand_total_difference(issue["operands"])
      end

    [component, grand_total_difference(issue["grand_total_operands"])]
    |> Enum.reject(&is_nil/1)
  end

  defp amount_difference(label, %{"printed" => printed, "derived" => derived})
       when is_number(printed) and is_number(derived),
       do: "Printed #{label} is #{rupees(printed)}; extracted lines total #{rupees(derived)}."

  defp amount_difference(_label, _operands), do: nil

  defp grand_total_difference(%{"printed" => printed, "derived" => derived})
       when is_number(printed) and is_number(derived),
       do:
         "Printed invoice total is #{rupees(printed)}; extracted lines total #{rupees(derived)}."

  defp grand_total_difference(_operands), do: nil

  defp rate(value) when is_number(value) and value == trunc(value), do: "#{trunc(value)}%"
  defp rate(value), do: "#{value}%"

  defp rupees(value), do: Formatters.format_money_with_paise(round(value * 100))

  defp human_join([one]), do: one
  defp human_join([one, two]), do: "#{one} and #{two}"

  defp human_join(items) do
    {last, rest} = List.pop_at(items, -1)
    Enum.join(rest, ", ") <> ", and " <> last
  end

  defp capitalize_first(<<first::utf8, rest::binary>>),
    do: String.upcase(<<first::utf8>>) <> rest

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
