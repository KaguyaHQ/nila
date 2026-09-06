defmodule Nila.Gst.Sales.InvoiceValidation do
  @moduledoc """
  Intrinsic validation for normalized sales invoices.

  Checks operate on integer paise (or exact `Decimal` paise for rate products).
  The rupee-shaped operands are presentation evidence only; they never decide
  whether a check passed.
  """

  alias Nila.Gst.Issues
  alias Nila.Gst.InvoiceFacts
  alias Nila.Gst.InvoiceNumber
  alias Nila.Gst.Money
  alias Nila.Gst.StateCodes
  alias Nila.Gstin
  alias Nila.Gst.Purchase.Books
  alias Nila.Gst.Sales.Invoice

  @money_tolerance_paise 50
  @bucket_tolerance_paise 1
  @printed_total_codes ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch)

  @doc "Arithmetic outcomes for one invoice, including passed checks."
  def checks(invoice) do
    invoice = InvoiceFacts.sales!(invoice)

    line_arithmetic_checks(invoice) ++
      split_equality_checks(invoice) ++ printed_total_checks(invoice)
  end

  @doc "Totals available for comparison, in rupees; missing inputs remain nil."
  def comparison_totals(invoice) do
    totals = invoice |> InvoiceFacts.sales!() |> invoice_totals()

    %{
      taxable: rupee_number(totals.taxable_paise),
      tax: rupee_number(totals.tax_paise),
      total: rupee_number(add_paise(totals.taxable_paise, totals.tax_paise))
    }
  end

  @doc "Every invoice-level issue, independent of month and output completeness."
  def issues(invoices) when is_list(invoices) do
    Enum.flat_map(invoices, fn invoice -> invoice |> InvoiceFacts.sales!() |> invoice_issues() end)
  end

  @doc "One blocking issue per duplicate active invoice-number group."
  def duplicate_number_issues(invoices) do
    invoices = Enum.map(invoices, &InvoiceFacts.sales!/1)

    invoices
    |> Enum.filter(&(is_binary(&1.number) and String.trim(&1.number) != ""))
    |> Enum.group_by(&{document_type(&1), InvoiceNumber.key(&1.number)})
    |> Enum.filter(fn {_key, members} -> length(members) > 1 end)
    |> Enum.map(fn {_key, members} ->
      invoice_number = hd(members).number
      source_ids = members |> Enum.map(&(&1.id || &1.number)) |> Enum.sort()

      %{
        "invoice" => invoice_number,
        "source_ids" => source_ids,
        "code" => "duplicate_invoice_number",
        "level" => Issues.level_for("duplicate_invoice_number"),
        "message" =>
          "invoice number #{invoice_number} belongs to #{length(source_ids)} active source rows; correct a misread number or exclude only a confirmed duplicate copy",
        "fields" => ["invoice_number"],
        "target" => "duplicate_invoice_number|#{invoice_number}|#{Enum.join(source_ids, ",")}"
      }
    end)
  end

  defp arithmetic_issues(invoice) do
    invoice
    |> checks()
    |> Enum.reject(& &1["passed"])
    |> failed_check_issues(invoice)
  end

  defp invoice_issues(invoice) do
    document_type_issues(invoice) ++
      filing_classification_issues(invoice) ++
      invoice_number_issues(invoice) ++
      invoice_date_issues(invoice) ++
      missing_taxable_value_issues(invoice) ++
      arithmetic_issues(invoice) ++
      gstin_issues(invoice) ++
      verification_issues(invoice) ++
      b2c_hsn_issues(invoice) ++
      mixed_head_issues(invoice) ++
      consistency_issues(invoice) ++
      lopsided_split_issues(invoice) ++
      furniture_row_issues(invoice) ++ bucket_rounding_issues(invoice)
  end

  defp line_arithmetic_checks(invoice) do
    invoice.lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, index} ->
      taxable_paise = line.taxable_paise
      tax_paise = line_tax_paise(line)
      rate = line_rate(line)

      if is_nil(taxable_paise) or not tax_amounts_complete?(line) or
           (taxable_paise == 0 and tax_paise == 0 and Decimal.equal?(rate, 0)) do
        []
      else
        expected_paise =
          Decimal.mult(Decimal.new(taxable_paise), rate) |> Decimal.div(100)

        [
          %{
            "code" => "line_arithmetic",
            "line" => index,
            "operands" => %{
              "taxable" => rupee_number(taxable_paise),
              "rate" => decimal_number(rate),
              "expected" => rupee_number(expected_paise),
              "actual" => rupee_number(tax_paise)
            },
            "passed" => close_paise?(tax_paise, expected_paise),
            "fields" =>
              taxable_correction_fields(line, index - 1) ++
                [
                  "line_items[#{index - 1}].cgst_amount",
                  "line_items[#{index - 1}].sgst_amount",
                  "line_items[#{index - 1}].igst_amount"
                ]
          }
        ]
      end
    end)
  end

  defp taxable_correction_fields(line, index) do
    case line.taxable_value_basis do
      :printed_taxable_value ->
        ["line_items[#{index}].printed_taxable_value"]

      basis
      when basis in [
             :derived_from_inclusive_line_amount,
             :printed_exclusive_line_amount,
             :line_amount_plus_tax_equals_total,
             :line_amount_times_rate_equals_tax
           ] ->
        [
          "line_items[#{index}].printed_line_amount",
          "line_items[#{index}].line_amount_tax_inclusion"
        ]

      _other ->
        ["line_items[#{index}].taxable_value"]
    end
  end

  defp split_equality_checks(invoice) do
    invoice.lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, index} ->
      if is_integer(line.tax_paise.cgst) and is_integer(line.tax_paise.sgst) do
        cgst_paise = line.tax_paise.cgst
        sgst_paise = line.tax_paise.sgst

        [
          %{
            "code" => "cgst_sgst_unequal",
            "line" => index,
            "operands" => %{
              "cgst" => rupee_number(cgst_paise),
              "sgst" => rupee_number(sgst_paise)
            },
            "passed" => close_paise?(cgst_paise, sgst_paise),
            "fields" => [
              "line_items[#{index - 1}].cgst_amount",
              "line_items[#{index - 1}].sgst_amount"
            ]
          }
        ]
      else
        []
      end
    end)
  end

  defp printed_total_checks(invoice) do
    totals = invoice_totals(invoice)

    [
      {"printed_taxable_mismatch", invoice.printed_taxable_paise, totals.taxable_paise,
       ["printed_total_taxable", "line_items"]},
      {"printed_tax_mismatch", printed_tax_paise(invoice), totals.tax_paise,
       ["printed_total_tax", "printed_tax_totals", "line_items"]},
      {"grand_total_mismatch", invoice.printed_total_paise,
       add_paise(totals.taxable_paise, totals.tax_paise), ["printed_grand_total", "line_items"]}
    ]
    |> Enum.flat_map(fn {code, printed, derived_paise, fields} ->
      case {printed, derived_paise} do
        {printed_paise, derived_paise}
        when is_integer(printed_paise) and is_integer(derived_paise) ->
          [
            %{
              "code" => code,
              "operands" => %{
                "printed" => rupee_number(printed_paise),
                "derived" => rupee_number(derived_paise)
              },
              "passed" => close_paise?(printed_paise, derived_paise),
              "fields" => fields
            }
          ]

        _missing_or_incomplete ->
          []
      end
    end)
  end

  defp failed_check_issues(failed, invoice) do
    {printed, per_line} = Enum.split_with(failed, &(&1["code"] in @printed_total_codes))

    line_issues =
      per_line
      |> Enum.map(& &1["code"])
      |> Enum.uniq()
      |> Enum.map(fn code ->
        line_check_issue(invoice, code, Enum.filter(per_line, &(&1["code"] == code)))
      end)

    line_issues ++ printed_total_issues(invoice, printed)
  end

  defp line_check_issue(invoice, code, checks) do
    invoice
    |> issue(
      code,
      Enum.map_join(checks, "; ", &check_message/1),
      checks |> Enum.flat_map(& &1["fields"]) |> Enum.uniq()
    )
    |> Map.put("lines", Enum.map(checks, & &1["line"]))
  end

  defp printed_total_issues(_invoice, []), do: []

  defp printed_total_issues(invoice, failed) do
    {grand, components} = Enum.split_with(failed, &(&1["code"] == "grand_total_mismatch"))

    if components != [] and grand_total_explained?(invoice, grand) do
      Enum.map(components, &collapsed_printed_issue(invoice, &1, grand))
    else
      Enum.map(failed, &check_issue(invoice, &1))
    end
  end

  defp grand_total_explained?(_invoice, []), do: false

  defp grand_total_explained?(invoice, [%{"operands" => ops}]) do
    totals = invoice_totals(invoice)

    explained =
      printed_delta(invoice.printed_taxable_paise, totals.taxable_paise) +
        printed_delta(printed_tax_paise(invoice), totals.tax_paise)

    grand_delta = Money.paise(ops["printed"]) - Money.paise(ops["derived"])
    abs(grand_delta - explained) <= 2 * @money_tolerance_paise
  end

  defp printed_tax_paise(invoice) do
    invoice
    |> InvoiceFacts.to_sales_map()
    |> Nila.Gst.Extraction.TaxComponents.printed_tax_total()
    |> case do
      nil -> nil
      amount -> Money.paise(amount)
    end
  end

  defp printed_delta(nil, _derived_paise), do: 0
  defp printed_delta(_printed, nil), do: 0
  defp printed_delta(printed_paise, derived_paise), do: printed_paise - derived_paise

  defp collapsed_printed_issue(invoice, %{"code" => code} = component, [grand]) do
    ops = grand["operands"]

    message =
      check_message(component) <>
        " — and the printed bill total, which is taxable + tax, is out by exactly that much " <>
        "(printed #{round2(ops["printed"])}, derived #{round2(ops["derived"])})"

    invoice
    |> issue(
      code,
      message,
      [component, grand] |> Enum.flat_map(& &1["fields"]) |> Enum.uniq()
    )
    |> Map.put("operands", component["operands"])
    |> Map.put("grand_total_operands", grand["operands"])
  end

  defp check_issue(invoice, %{"code" => code, "fields" => fields} = check) do
    invoice
    |> issue(code, check_message(check), fields)
    |> Map.put("operands", check["operands"])
  end

  defp check_message(%{"code" => "line_arithmetic", "line" => index, "operands" => ops}) do
    "line #{index} tax #{ops["actual"]} does not match #{ops["taxable"]} × #{ops["rate"]}% = #{round2(ops["expected"])}"
  end

  defp check_message(%{"code" => "cgst_sgst_unequal", "line" => index, "operands" => ops}) do
    "line #{index} CGST #{ops["cgst"]} and SGST #{ops["sgst"]} are not equal halves of the tax"
  end

  defp check_message(%{"code" => code, "operands" => ops}) do
    "#{total_claim(code)}: printed #{round2(ops["printed"])}, derived #{round2(ops["derived"])}"
  end

  defp total_claim("printed_taxable_mismatch"),
    do: "printed taxable total does not match line taxable sum"

  defp total_claim("printed_tax_mismatch"), do: "printed tax total does not match line tax sum"

  defp total_claim("grand_total_mismatch"),
    do: "printed grand total does not match line taxable + tax"

  defp issue(invoice, code, message, fields) do
    issue(invoice, code, message, fields, Issues.level_for(code))
  end

  defp issue(invoice, code, message, fields, level) do
    %{
      "invoice" => invoice.number,
      "source_id" => invoice.id || invoice.number,
      "code" => code,
      "message" => message,
      "fields" => fields,
      "level" => level
    }
  end

  defp document_type(invoice), do: invoice.document_type || "invoice"

  defp recipient_registration(invoice) do
    invoice.evidence["recipient_registration"] ||
      if(is_nil(blank_to_nil(party_gstin(invoice.recipient))),
        do: "unknown",
        else: "registered"
      )
  end

  defp document_status(invoice), do: invoice.evidence["document_status"] || "active"

  defp supply_type(invoice) do
    invoice.evidence["supply_type"] ||
      if(get_in(invoice.evidence, ["document", "export"]), do: "export", else: "taxable")
  end

  defp marker_document_type(%{"credit_note" => true, "debit_note" => true}), do: nil
  defp marker_document_type(%{"credit_note" => true}), do: "credit_note"
  defp marker_document_type(%{"debit_note" => true}), do: "debit_note"
  defp marker_document_type(_document), do: nil

  defp valid_gstin?(gstin), do: Gstin.valid_extracted?(gstin)
  defp state_code(gstin), do: StateCodes.from_gstin(gstin)

  defp taxable_values_complete?(invoice),
    do: Enum.all?(invoice.lines, &is_integer(&1.taxable_paise))

  defp field_value(invoice, "seller_gstin"), do: party_gstin(invoice.issuer)
  defp field_value(invoice, "buyer_gstin"), do: party_gstin(invoice.recipient)
  defp field_value(invoice, "invoice_number"), do: invoice.number
  defp field_value(invoice, "invoice_date"), do: invoice.date || invoice.unreadable_date
  defp field_value(invoice, "place_of_supply"), do: invoice.place_of_supply

  defp field_value(invoice, field) do
    invoice
    |> InvoiceFacts.to_sales_map()
    |> Invoice.field_value(field)
  end

  defp computed_bucket_tax([], _rate, _mode),
    do: %{taxable_paise: 0, cgst_paise: 0, sgst_paise: 0, igst_paise: 0}

  defp computed_bucket_tax(lines, rate, :interstate) do
    taxable_paise = sum_line_paise(lines, :taxable)
    igst_paise = Decimal.mult(Decimal.new(taxable_paise), rate) |> Decimal.div(100)

    %{taxable_paise: taxable_paise, cgst_paise: 0, sgst_paise: 0, igst_paise: igst_paise}
  end

  defp computed_bucket_tax(lines, rate, :intrastate) do
    taxable_paise = sum_line_paise(lines, :taxable)
    side_paise = Decimal.mult(Decimal.new(taxable_paise), rate) |> Decimal.div(200)

    %{
      taxable_paise: taxable_paise,
      cgst_paise: side_paise,
      sgst_paise: side_paise,
      igst_paise: 0
    }
  end

  defp tax_mode(line) do
    if optional_paise(line.tax_paise.igst) > 0 or decimal_positive?(line.igst_rate),
      do: :interstate,
      else: :intrastate
  end

  defp degenerate_line?(line) do
    zeroish_paise?(line.taxable_paise) and decimal_zeroish?(line.quantity) and
      zeroish_paise?(line.tax_paise.cgst) and zeroish_paise?(line.tax_paise.sgst) and
      zeroish_paise?(line.tax_paise.igst)
  end

  defp furniture_description?(description) do
    description = description |> to_string() |> String.trim()

    String.match?(description, ~r/^total\b/i) or
      String.match?(description, ~r/amount.*\bwords\b/i)
  end

  defp zeroish_paise?(value), do: is_nil(value) or value == 0
  defp decimal_zeroish?(nil), do: true
  defp decimal_zeroish?(value), do: Decimal.equal?(value, 0)

  defp hsn_code(nil), do: nil
  defp hsn_code(hsn), do: hsn |> to_string() |> String.replace(~r/\D/, "")

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp document_type_issues(invoice) do
    document = invoice.evidence["document"] || %{}
    marked_type = marker_document_type(document)
    extracted_type = document["extracted_type"]
    canonical = document_type(invoice)

    cond do
      canonical not in ~w(invoice credit_note debit_note) ->
        [
          issue(
            invoice,
            "invalid_document_type",
            "document type #{inspect(canonical)} is not invoice, credit_note, or debit_note",
            ["document_type"],
            Issues.level_for("invalid_document_type")
          )
        ]

      document["credit_note"] == true and document["debit_note"] == true ->
        [
          issue(
            invoice,
            "document_type_conflict",
            "the document carries both credit-note and debit-note markers",
            ["document_type"],
            Issues.level_for("document_type_conflict")
          )
        ]

      is_binary(extracted_type) and not is_nil(marked_type) and extracted_type != marked_type and
          canonical != marked_type ->
        [
          issue(
            invoice,
            "document_type_conflict",
            "structured extraction says #{extracted_type}, while the document heading says #{marked_type}",
            ["document_type"],
            Issues.level_for("document_type_conflict")
          )
        ]

      extracted_type in ~w(credit_note debit_note) and is_nil(marked_type) and
          canonical == extracted_type ->
        [
          issue(
            invoice,
            "document_type_conflict",
            "structured extraction says #{extracted_type}, but no matching document heading was found",
            ["document_type"],
            Issues.level_for("document_type_conflict")
          )
        ]

      true ->
        []
    end
  end

  defp filing_classification_issues(invoice) do
    registration = recipient_registration(invoice)
    buyer_gstin = party_gstin(invoice.recipient)
    pos = invoice.place_of_supply

    []
    |> maybe_classification_issue(
      registration == "unknown",
      invoice,
      "unknown_recipient_registration",
      "recipient registration is unknown; classify it before choosing B2B or B2C",
      ["recipient_registration", "buyer_gstin"]
    )
    |> maybe_classification_issue(
      registration == "registered" and is_nil(buyer_gstin),
      invoice,
      "recipient_registration_conflict",
      "recipient is classified as registered but no buyer GSTIN was extracted",
      ["recipient_registration", "buyer_gstin"]
    )
    |> maybe_classification_issue(
      registration == "unregistered" and not is_nil(buyer_gstin),
      invoice,
      "recipient_registration_conflict",
      "recipient is classified as unregistered but the document carries a buyer GSTIN",
      ["recipient_registration", "buyer_gstin"]
    )
    |> maybe_classification_issue(
      registration == "unregistered" and is_nil(pos),
      invoice,
      "missing_place_of_supply",
      "an unregistered supply needs an explicit place of supply for B2CS/B2CL classification",
      ["place_of_supply"]
    )
    |> maybe_classification_issue(
      is_binary(pos) and is_nil(StateCodes.name_for(pos)),
      invoice,
      "invalid_place_of_supply",
      "place of supply #{inspect(pos)} is not a known GST state code",
      ["place_of_supply"]
    )
    |> maybe_classification_issue(
      document_status(invoice) == "unknown",
      invoice,
      "unknown_document_status",
      "document status is unknown; confirm it is active, cancelled, or an amendment",
      ["document_status"]
    )
    |> maybe_classification_issue(
      supply_type(invoice) == "unknown",
      invoice,
      "unknown_supply_type",
      "supply treatment is unknown; classify it before filing",
      ["supply_type"]
    )
  end

  defp maybe_classification_issue(issues, false, _invoice, _code, _message, _fields),
    do: issues

  defp maybe_classification_issue(issues, true, invoice, code, message, fields) do
    issues ++ [issue(invoice, code, message, fields, Issues.level_for(code))]
  end

  defp verification_issues(invoice) do
    fields =
      invoice.verification
      |> Map.get("failed_checks")
      |> List.wrap()
      |> Enum.filter(&(&1["kind"] in ~w(source_presence grounding)))
      |> Enum.map(&Invoice.verification_field/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(not is_nil(field_value(invoice, &1))))
      |> Enum.uniq()

    if fields == [] do
      []
    else
      [
        issue(
          invoice,
          "ungrounded_extracted_value",
          "AI read a value that does not appear on the invoice. Check the highlighted field against the source before filing.",
          fields,
          Issues.level_for("ungrounded_extracted_value")
        )
      ]
    end
  end

  defp b2c_hsn_issues(invoice) do
    if recipient_registration(invoice) == "unregistered" and document_type(invoice) == "invoice" and
         document_status(invoice) == "active" and supply_type(invoice) == "taxable" do
      missing =
        invoice.lines
        |> Enum.with_index()
        |> Enum.filter(fn {line, _index} ->
          hsn = hsn_code(line.hsn_sac)

          is_binary(hsn) and not String.starts_with?(hsn, "99") and
            is_nil(blank_to_nil(line.uom))
        end)

      case missing do
        [] ->
          []

        lines ->
          indexes = Enum.map(lines, fn {_line, index} -> index end)

          [
            invoice
            |> issue(
              "missing_uom",
              "B2C HSN lines #{Enum.map_join(indexes, ", ", &(&1 + 1))} have no unit of measurement; confirm the item name and UQC before filing",
              Enum.flat_map(
                indexes,
                &[
                  "line_items[#{&1}].item_name",
                  "line_items[#{&1}].uom"
                ]
              ),
              Issues.level_for("missing_uom")
            )
            |> Map.put("lines", Enum.map(indexes, &(&1 + 1)))
          ]
      end
    else
      []
    end
  end

  defp missing_taxable_value_issues(invoice) do
    missing =
      invoice.lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _index} -> is_nil(line.taxable_paise) end)

    case missing do
      [] ->
        []

      lines ->
        numbers = Enum.map(lines, fn {_line, index} -> index end)

        fields =
          Enum.flat_map(lines, fn {_line, index} ->
            zero = index - 1

            [
              "line_items[#{zero}].taxable_value",
              "line_items[#{zero}].line_amount_tax_inclusion"
            ]
          end)

        [
          invoice
          |> issue(
            "missing_taxable_value",
            "taxable value could not be established for #{line_word(numbers)} #{Enum.join(numbers, ", ")}; correct the taxable value or whether the printed line amount includes GST",
            fields,
            Issues.level_for("missing_taxable_value")
          )
          |> Map.put("lines", numbers)
        ]
    end
  end

  defp line_word([_one]), do: "line"
  defp line_word(_many), do: "lines"

  defp invoice_date_issues(invoice) do
    printed = invoice.date || invoice.unreadable_date

    cond do
      match?(%Date{}, printed) ->
        []

      not sales_invoice_has_values?(invoice) ->
        []

      blank_date?(printed) ->
        [
          issue(
            invoice,
            "unreadable_invoice_date",
            "the invoice carries values but no invoice date was extracted — read it off the bill",
            ["invoice_date"],
            Issues.level_for("unreadable_invoice_date")
          )
        ]

      is_binary(printed) and Books.parse_date(printed) ->
        []

      true ->
        [
          issue(
            invoice,
            "unreadable_invoice_date",
            "the invoice date reads #{inspect(printed)}, which is not a date — correct it " <>
              "before filing",
            ["invoice_date"],
            Issues.level_for("unreadable_invoice_date")
          )
        ]
    end
  end

  defp blank_date?(nil), do: true
  defp blank_date?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_date?(_value), do: false

  defp invoice_number_issues(invoice) do
    smell = InvoiceNumber.smell(invoice.number, sales_invoice_has_values?(invoice))

    case smell do
      nil ->
        []

      smell ->
        [
          issue(
            invoice,
            "implausible_invoice_number",
            smell_message(smell, invoice.number),
            ["invoice_number"],
            Issues.level_for("implausible_invoice_number")
          )
        ]
    end
  end

  defp smell_message(:phone_number, invoice_number),
    do: "invoice number #{invoice_number} looks like a phone number — verify it against the bill"

  defp smell_message(:date, invoice_number),
    do: "invoice number #{invoice_number} looks like a date — verify it against the bill"

  defp smell_message(:missing, _invoice_number),
    do:
      "the invoice carries values but no invoice number was extracted — verify it against the bill"

  defp sales_invoice_has_values?(invoice) do
    Enum.any?(
      [
        invoice.printed_taxable_paise,
        printed_tax_paise(invoice),
        invoice.printed_total_paise
      ],
      &(optional_paise(&1) != 0)
    ) or
      Enum.any?(invoice.lines, fn line ->
        optional_paise(line.taxable_paise) != 0 or optional_paise(line.tax_paise.cgst) != 0 or
          optional_paise(line.tax_paise.sgst) != 0 or optional_paise(line.tax_paise.igst) != 0
      end)
  end

  defp furniture_row_issues(invoice) do
    line_issue(invoice, "furniture_row_with_values", fn line ->
      furniture_description?(line.description) and not degenerate_line?(line)
    end)
  end

  defp bucket_rounding_issues(invoice) do
    if taxable_values_complete?(invoice) do
      bucket_rounding_issues_for_complete_invoice(invoice)
    else
      []
    end
  end

  defp bucket_rounding_issues_for_complete_invoice(invoice) do
    invoice.lines
    |> Enum.group_by(&(line_rate(&1) |> Decimal.normalize() |> Decimal.to_string(:normal)))
    |> Enum.flat_map(fn {rate, lines} ->
      rate = Decimal.new(rate)

      lines
      |> Enum.group_by(&tax_mode/1)
      |> Enum.flat_map(fn {mode, mode_lines} ->
        bucket_tax = computed_bucket_tax(mode_lines, rate, mode)

        case mode do
          :interstate ->
            rounding_issue(
              invoice,
              rate,
              mode_lines,
              "iamt",
              sum_line_paise(mode_lines, :igst),
              bucket_tax.igst_paise
            )

          :intrastate ->
            rounding_issue(
              invoice,
              rate,
              mode_lines,
              "camt",
              sum_line_paise(mode_lines, :cgst),
              bucket_tax.cgst_paise
            ) ++
              rounding_issue(
                invoice,
                rate,
                mode_lines,
                "samt",
                sum_line_paise(mode_lines, :sgst),
                bucket_tax.sgst_paise
              )
        end
      end)
    end)
  end

  defp rounding_issue(invoice, rate, lines, field, extracted_paise, computed_paise) do
    delta_paise = Decimal.sub(Decimal.new(extracted_paise), decimal(computed_paise))
    delta = delta_paise |> rupee_number() |> round2()
    extracted = extracted_paise |> rupee_number() |> round2()
    computed = computed_paise |> rupee_number() |> round2()
    display_rate = decimal_number(rate)

    cond do
      decimal_abs_lte?(delta_paise, Decimal.new(@bucket_tolerance_paise)) ->
        []

      decimal_abs_lte?(delta_paise, rounding_variance_bound_paise(lines)) ->
        [
          issue(
            invoice,
            "rounding_variance",
            "#{field} line-tax sum #{extracted} differs from bucket taxable × #{display_rate}% #{computed} by #{delta}, within per-line rounding bound",
            ["line_items"],
            Issues.level_for("rounding_variance")
          )
        ]

      true ->
        [
          issue(
            invoice,
            "bucket_tax_mismatch",
            "#{field} line-tax sum #{extracted} differs from bucket taxable × #{display_rate}% #{computed} by #{delta}, beyond per-line rounding bound",
            ["line_items"],
            Issues.level_for("bucket_tax_mismatch")
          )
        ]
    end
  end

  defp rounding_variance_bound_paise(lines),
    do: Decimal.mult(Decimal.new("0.5"), length(lines))

  # A real intra-state line always carries both CGST and SGST. Lines with
  # exactly one of them (and no IGST) mean the extractor split one printed
  # row's stacked tax sub-rows into separate line items — the invoice-27
  # failure mode. One issue per invoice, not per line.
  defp lopsided_split_issues(invoice) do
    line_issue(invoice, "lopsided_tax_split", fn line ->
      is_nil(line.tax_paise.igst) and
        is_nil(line.tax_paise.cgst) != is_nil(line.tax_paise.sgst)
    end)
  end

  # One issue naming the 1-based line numbers a predicate matched, or none. Two
  # checks had written this out identically; the shape is the same every time
  # because the reviewer's question is the same every time — which rows?
  defp line_issue(invoice, code, predicate) do
    lines =
      invoice.lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _index} -> predicate.(line) end)
      |> Enum.map(fn {_line, index} -> index end)

    case lines do
      [] ->
        []

      lines ->
        [
          invoice
          |> issue(
            code,
            line_issue_message(code, lines),
            ["line_items"],
            Issues.level_for(code)
          )
          |> Map.put("lines", lines)
        ]
    end
  end

  defp line_issue_message("furniture_row_with_values", lines),
    do:
      "furniture rows #{Enum.join(lines, ", ")} carry taxable/tax values — keep for review, do not silently drop"

  defp line_issue_message("lopsided_tax_split", lines),
    do:
      "lines #{Enum.join(lines, ", ")} carry only one of CGST/SGST — stacked tax sub-rows were likely split into separate line items"

  defp gstin_issues(invoice) do
    seller_gstin = party_gstin(invoice.issuer)
    buyer_gstin = party_gstin(invoice.recipient)

    ([{"seller_gstin", seller_gstin}] ++
       if(is_nil(buyer_gstin),
         do: [],
         else: [{"buyer_gstin", buyer_gstin}]
       ))
    |> Enum.flat_map(fn {field, gstin} ->
      if valid_gstin?(gstin) do
        []
      else
        [
          issue(
            invoice,
            "invalid_gstin",
            "#{field} #{inspect(gstin)} fails GSTIN checksum",
            [field],
            Issues.level_for("invalid_gstin")
          )
        ]
      end
    end)
  end

  # One supply has one place of supply, so an invoice cannot carry both IGST and
  # CGST/SGST. This needs no GSTIN to judge and admits no inference: the
  # document contradicts itself, whatever the parties' states turn out to be.
  #
  # It escapes every other check. `consistency_issues/1` compares the GSTIN pair
  # against the heads, and both of its branches require one side to be at zero —
  # a bill carrying both falls through. `lopsided_split_issues/1` catches one of
  # CGST/SGST, not both modes. And the totals still agree, so
  # `printed_tax_mismatch` passes. Meanwhile `derive_invoice/2` picks one mode
  # for the whole invoice and recomputes: a KA→TN bill with ₹900 IGST and ₹450 +
  # ₹450 files as ₹1,800 IGST, and the CGST/SGST the client actually charged
  # disappears from the return without a single check firing.
  #
  # The filing is arguably right — interstate is all-IGST. The invoice is what
  # is wrong: tax was collected under a head that will not be remitted, and the
  # buyer's 2B will not match the paper in their hands.
  defp mixed_head_issues(invoice) do
    igst_paise = sum_line_paise(invoice.lines, :igst)
    split = split_tax(invoice)

    if igst_paise > 0 and split > 0 do
      igst = rupee_number(igst_paise)
      split_rupees = rupee_number(split)

      [
        invoice
        |> issue(
          "mixed_tax_heads",
          "invoice carries both IGST (#{round2(igst)}) and CGST/SGST (#{round2(split_rupees)}) — one supply has one place of supply, so only one head can be correct",
          ["line_items"],
          Issues.level_for("mixed_tax_heads")
        )
        |> Map.merge(%{
          "tax_heads" => positive_tax_heads(invoice),
          "igst" => round2(igst),
          "split_tax" => round2(split_rupees)
        })
      ]
    else
      []
    end
  end

  defp split_tax(invoice),
    do: sum_line_paise(invoice.lines, :cgst) + sum_line_paise(invoice.lines, :sgst)

  defp positive_tax_heads(invoice) do
    [
      {"igst", sum_line_paise(invoice.lines, :igst)},
      {"cgst", sum_line_paise(invoice.lines, :cgst)},
      {"sgst", sum_line_paise(invoice.lines, :sgst)}
    ]
    |> Enum.filter(fn {_head, amount} -> amount > 0 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp consistency_issues(invoice) do
    seller_state = state_code(party_gstin(invoice.issuer))
    buyer_state = state_code(party_gstin(invoice.recipient))
    place_of_supply = invoice.place_of_supply || buyer_state
    interstate? = seller_state && place_of_supply && seller_state != place_of_supply
    igst = sum_line_paise(invoice.lines, :igst)
    split = split_tax(invoice)

    cond do
      # Both heads present is `mixed_tax_heads`, which says something stronger
      # and does not depend on the GSTINs being right. Raising both would ask a
      # reviewer to answer the same malformed invoice twice.
      igst > 0 and split > 0 ->
        []

      is_nil(seller_state) or is_nil(place_of_supply) ->
        []

      interstate? and igst <= 0 and split > 0 ->
        tax_treatment_issue(invoice, seller_state, place_of_supply, "igst")

      not interstate? and split <= 0 and igst > 0 ->
        tax_treatment_issue(invoice, seller_state, place_of_supply, "cgst_sgst")

      true ->
        []
    end
  end

  defp tax_treatment_issue(invoice, seller_state, place_of_supply, suggested_treatment) do
    inferred? = is_nil(invoice.place_of_supply)
    code = if(inferred?, do: "tax_treatment_uncertain", else: "tax_split_mismatch")

    message =
      if inferred?,
        do: "party GSTIN states and extracted tax heads disagree; confirm the tax treatment",
        else: "place of supply and extracted tax heads disagree"

    [
      invoice
      |> issue(
        code,
        message,
        [if(inferred?, do: "buyer_gstin", else: "place_of_supply"), "line_items"],
        Issues.level_for(code)
      )
      |> Map.merge(%{
        "seller_state" => seller_state,
        "place_of_supply" => place_of_supply,
        "place_field" => if(inferred?, do: "buyer_gstin", else: "place_of_supply"),
        "tax_heads" => positive_tax_heads(invoice),
        "suggested_tax_treatment" => suggested_treatment
      })
    ]
  end

  defp line_tax_paise(line) do
    optional_paise(line.tax_paise.cgst) + optional_paise(line.tax_paise.sgst) +
      optional_paise(line.tax_paise.igst)
  end

  defp line_rate(line) do
    [line.cgst_rate, line.sgst_rate, line.igst_rate]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp close_paise?(left, right) do
    left = Decimal.new(left)
    right = decimal(right)

    left
    |> Decimal.sub(right)
    |> Decimal.abs()
    |> Decimal.compare(Decimal.new(@money_tolerance_paise))
    |> then(&(&1 in [:lt, :eq]))
  end

  defp add_paise(nil, _right), do: nil
  defp add_paise(_left, nil), do: nil
  defp add_paise(left, right), do: left + right

  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp rupee_number(nil), do: nil

  defp rupee_number(%Decimal{} = paise),
    do: paise |> Decimal.div(100) |> Decimal.to_float()

  defp rupee_number(paise) when is_integer(paise), do: paise / 100

  defp decimal_number(%Decimal{} = value) do
    if Decimal.equal?(value, Decimal.round(value, 0)) do
      Decimal.to_integer(value)
    else
      Decimal.to_float(value)
    end
  end

  defp optional_paise(nil), do: 0
  defp optional_paise(value), do: value

  defp sum_line_paise(lines, :taxable),
    do: Enum.sum(Enum.map(lines, &optional_paise(&1.taxable_paise)))

  defp sum_line_paise(lines, head),
    do: Enum.sum(Enum.map(lines, &optional_paise(Map.fetch!(&1.tax_paise, head))))

  defp invoice_totals(invoice) do
    taxable_paise =
      if taxable_values_complete?(invoice), do: sum_line_paise(invoice.lines, :taxable)

    tax_paise =
      if invoice.lines != [] and Enum.all?(invoice.lines, &tax_amounts_complete?/1),
        do: line_tax_paise_sum(invoice.lines)

    %{taxable_paise: taxable_paise, tax_paise: tax_paise}
  end

  # Absent heads may be inapplicable; a stated positive rate still needs an amount.
  # With no amounts at all, only an explicit zero rate establishes zero tax.
  defp tax_amounts_complete?(line) do
    heads = [{:cgst, line.cgst_rate}, {:sgst, line.sgst_rate}, {:igst, line.igst_rate}]

    known? =
      Enum.any?(heads, fn {head, rate} ->
        is_integer(line.tax_paise[head]) or (not is_nil(rate) and Decimal.equal?(rate, 0))
      end)

    known? and
      Enum.all?(heads, fn {head, rate} ->
        not decimal_positive?(rate) or is_integer(line.tax_paise[head])
      end) and
      is_nil(line.tax_paise.cgst) == is_nil(line.tax_paise.sgst)
  end

  defp line_tax_paise_sum(lines), do: Enum.sum(Enum.map(lines, &line_tax_paise/1))

  defp decimal_positive?(nil), do: false
  defp decimal_positive?(value), do: Decimal.compare(value, 0) == :gt

  defp decimal_abs_lte?(left, right),
    do: left |> Decimal.abs() |> Decimal.compare(right) |> then(&(&1 in [:lt, :eq]))

  defp party_gstin(nil), do: nil
  defp party_gstin(party), do: party.gstin

  defp round2(value), do: Float.round(value / 1, 2)
end
