defmodule Nila.Gst.Sales.InvoiceValidation do
  @moduledoc """
  Intrinsic validation for normalized sales invoices.

  Checks operate on integer paise (or exact `Decimal` paise for rate products).
  The rupee-shaped operands are presentation evidence only; they never decide
  whether a check passed.
  """

  alias Nila.Gst.Issues
  alias Nila.Gst.InvoiceNumber
  alias Nila.Gst.Money
  alias Nila.Gst.StateCodes
  alias Nila.Gst.Purchase.Books
  alias Nila.Gst.Sales.Invoice

  @money_tolerance_paise 50
  @diff_tolerance 0.01
  @printed_total_codes ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch)

  @doc "Arithmetic outcomes for one invoice, including passed checks."
  def checks(invoice) do
    line_arithmetic_checks(invoice) ++
      split_equality_checks(invoice) ++ printed_total_checks(invoice)
  end

  @doc "Every invoice-level issue, independent of month and output completeness."
  def issues(invoices) when is_list(invoices), do: Enum.flat_map(invoices, &invoice_issues/1)

  @doc "One blocking issue per duplicate active invoice-number group."
  def duplicate_number_issues(invoices) do
    invoices
    |> Enum.filter(&(is_binary(&1["invoice_number"]) and String.trim(&1["invoice_number"]) != ""))
    |> Enum.group_by(&{document_type(&1), InvoiceNumber.key(&1["invoice_number"])})
    |> Enum.filter(fn {_key, members} -> length(members) > 1 end)
    |> Enum.map(fn {_key, members} ->
      invoice_number = members |> hd() |> Map.fetch!("invoice_number")
      source_ids = members |> Enum.map(&Invoice.source_id/1) |> Enum.sort()

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
    invoice["line_items"]
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, index} ->
      taxable = line["taxable_value"]
      taxable_paise = paise(taxable)
      tax_paise = line_tax_paise(line)
      rate = line_rate(line)

      if is_nil(taxable_paise) or (taxable_paise == 0 and tax_paise == 0 and rate == 0) do
        []
      else
        expected_paise =
          Decimal.mult(Decimal.new(taxable_paise), decimal(rate)) |> Decimal.div(100)

        [
          %{
            "code" => "line_arithmetic",
            "line" => index,
            "operands" => %{
              "taxable" => taxable,
              "rate" => rate,
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
    case line["taxable_value_basis"] do
      "printed_taxable_value" ->
        ["line_items[#{index}].printed_taxable_value"]

      basis
      when basis in ~w(derived_from_inclusive_line_amount printed_exclusive_line_amount line_amount_plus_tax_equals_total line_amount_times_rate_equals_tax) ->
        [
          "line_items[#{index}].printed_line_amount",
          "line_items[#{index}].line_amount_tax_inclusion"
        ]

      _other ->
        ["line_items[#{index}].taxable_value"]
    end
  end

  defp split_equality_checks(invoice) do
    invoice["line_items"]
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, index} ->
      if is_number(line["cgst_amount"]) and is_number(line["sgst_amount"]) do
        cgst_paise = Money.paise(line["cgst_amount"])
        sgst_paise = Money.paise(line["sgst_amount"])

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
    totals = Invoice.extracted_totals_paise(invoice)

    [
      {"printed_taxable_mismatch", invoice["printed_total_taxable"], totals.taxable_paise,
       ["printed_total_taxable", "line_items"]},
      {"printed_tax_mismatch", invoice["printed_total_tax"], totals.tax_paise,
       ["printed_total_tax", "line_items"]},
      {"grand_total_mismatch", invoice["printed_grand_total"],
       add_paise(totals.taxable_paise, totals.tax_paise), ["printed_grand_total", "line_items"]}
    ]
    |> Enum.flat_map(fn {code, printed, derived_paise, fields} ->
      case {Money.paise_or_error(printed), derived_paise} do
        {{:ok, printed_paise}, derived_paise} when is_integer(derived_paise) ->
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
    totals = Invoice.extracted_totals_paise(invoice)

    explained =
      printed_delta(invoice["printed_total_taxable"], totals.taxable_paise) +
        printed_delta(invoice["printed_total_tax"], totals.tax_paise)

    grand_delta = Money.paise(ops["printed"]) - Money.paise(ops["derived"])
    abs(grand_delta - explained) <= 2 * @money_tolerance_paise
  end

  defp printed_delta(nil, _derived_paise), do: 0
  defp printed_delta(_printed, nil), do: 0
  defp printed_delta(printed, derived_paise), do: Money.paise(printed) - derived_paise

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
      "invoice" => invoice["invoice_number"],
      "source_id" => Invoice.source_id(invoice),
      "code" => code,
      "message" => message,
      "fields" => fields,
      "level" => level
    }
  end

  defp document_type(invoice), do: invoice["document_type"] || "invoice"

  defp recipient_registration(invoice) do
    invoice["recipient_registration"] ||
      if(is_nil(blank_to_nil(invoice["buyer_gstin"])), do: "unknown", else: "registered")
  end

  defp document_status(invoice), do: invoice["document_status"] || "active"

  defp supply_type(invoice) do
    invoice["supply_type"] ||
      if(get_in(invoice, ["document", "export"]), do: "export", else: "taxable")
  end

  defp marker_document_type(%{"credit_note" => true, "debit_note" => true}), do: nil
  defp marker_document_type(%{"credit_note" => true}), do: "credit_note"
  defp marker_document_type(%{"debit_note" => true}), do: "debit_note"
  defp marker_document_type(_document), do: nil

  defp valid_gstin?(gstin) when is_binary(gstin),
    do: gstin |> String.trim() |> String.upcase() |> Nila.Gstin.valid?()

  defp valid_gstin?(_gstin), do: false

  defp state_code(nil), do: nil

  defp state_code(gstin) do
    gstin = to_string(gstin)
    if String.length(gstin) >= 2, do: String.slice(gstin, 0, 2)
  end

  defp effective_place_of_supply(invoice) do
    case invoice["place_of_supply"] do
      pos when is_binary(pos) -> if(StateCodes.name_for(pos), do: pos)
      _missing -> state_code(invoice["buyer_gstin"])
    end
  end

  defp taxable_values_complete?(invoice), do: Invoice.taxable_values_complete?(invoice)
  defp field_value(invoice, field), do: Invoice.field_value(invoice, field)

  defp sum(lines, field), do: lines |> List.wrap() |> Enum.map(&num(&1[field])) |> Enum.sum()

  defp computed_bucket_tax([], _rate, _mode), do: %{txval: 0, camt: 0, samt: 0, iamt: 0}

  defp computed_bucket_tax(lines, rate, :interstate) do
    txval = round2(sum(lines, "taxable_value"))
    %{txval: txval, camt: 0, samt: 0, iamt: round2(txval * num(rate) / 100)}
  end

  defp computed_bucket_tax(lines, rate, :intrastate) do
    txval = round2(sum(lines, "taxable_value"))
    side_tax = round2(txval * num(rate) / 200)
    %{txval: txval, camt: side_tax, samt: side_tax, iamt: 0}
  end

  defp tax_mode(line) do
    if num(line["igst_amount"]) > 0 or num(line["igst_rate"]) > 0,
      do: :interstate,
      else: :intrastate
  end

  defp degenerate_line?(line) do
    zeroish?(line["taxable_value"]) and zeroish?(line["quantity"]) and
      zeroish?(line["cgst_amount"]) and zeroish?(line["sgst_amount"]) and
      zeroish?(line["igst_amount"])
  end

  defp furniture_description?(description) do
    description = description |> to_string() |> String.trim()

    String.match?(description, ~r/^total\b/i) or
      String.match?(description, ~r/amount.*\bwords\b/i)
  end

  defp zeroish?(value), do: is_nil(value) or num(value) == 0
  defp close?(left, right, tolerance), do: abs(num(left) - num(right)) <= tolerance + 0.000001

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
    document = invoice["document"] || %{}
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
    buyer_gstin = invoice["buyer_gstin"]
    pos = invoice["place_of_supply"]

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
      invoice
      |> get_in(["verification", "failed_checks"])
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
        invoice["line_items"]
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.filter(fn {line, _index} ->
          hsn = hsn_code(line["hsn_sac"])

          is_binary(hsn) and not String.starts_with?(hsn, "99") and
            is_nil(blank_to_nil(line["uom"]))
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
      invoice["line_items"]
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _index} -> is_nil(line["taxable_value"]) end)

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

  defp invoice_date_issues(%{"invoice_date" => %Date{}}), do: []

  defp invoice_date_issues(invoice) do
    printed = invoice["invoice_date"]

    cond do
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
    smell =
      InvoiceNumber.smell(invoice["invoice_number"], sales_invoice_has_values?(invoice))

    case smell do
      nil ->
        []

      smell ->
        [
          issue(
            invoice,
            "implausible_invoice_number",
            smell_message(smell, invoice["invoice_number"]),
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
        invoice["printed_total_taxable"],
        invoice["printed_total_tax"],
        invoice["printed_grand_total"]
      ],
      &(num(&1) != 0)
    ) or
      Enum.any?(invoice["line_items"] || [], fn line ->
        num(line["taxable_value"]) != 0 or num(line["cgst_amount"]) != 0 or
          num(line["sgst_amount"]) != 0 or num(line["igst_amount"]) != 0
      end)
  end

  defp furniture_row_issues(invoice) do
    line_issue(invoice, "furniture_row_with_values", fn line ->
      furniture_description?(line["description"]) and not degenerate_line?(line)
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
    invoice["line_items"]
    |> Enum.group_by(&line_rate/1)
    |> Enum.flat_map(fn {rate, lines} ->
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
              sum(mode_lines, "igst_amount"),
              bucket_tax.iamt
            )

          :intrastate ->
            rounding_issue(
              invoice,
              rate,
              mode_lines,
              "camt",
              sum(mode_lines, "cgst_amount"),
              bucket_tax.camt
            ) ++
              rounding_issue(
                invoice,
                rate,
                mode_lines,
                "samt",
                sum(mode_lines, "sgst_amount"),
                bucket_tax.samt
              )
        end
      end)
    end)
  end

  defp rounding_issue(invoice, rate, lines, field, extracted, computed) do
    delta = round2(extracted - computed)

    cond do
      close?(extracted, computed, @diff_tolerance) ->
        []

      abs(delta) <= rounding_variance_bound(lines) ->
        [
          issue(
            invoice,
            "rounding_variance",
            "#{field} line-tax sum #{round2(extracted)} differs from bucket taxable × #{rate}% #{round2(computed)} by #{delta}, within per-line rounding bound",
            ["line_items"],
            Issues.level_for("rounding_variance")
          )
        ]

      true ->
        [
          issue(
            invoice,
            "bucket_tax_mismatch",
            "#{field} line-tax sum #{round2(extracted)} differs from bucket taxable × #{rate}% #{round2(computed)} by #{delta}, beyond per-line rounding bound",
            ["line_items"],
            Issues.level_for("bucket_tax_mismatch")
          )
        ]
    end
  end

  defp rounding_variance_bound(lines), do: 0.005 * length(lines) + 0.000001

  # A real intra-state line always carries both CGST and SGST. Lines with
  # exactly one of them (and no IGST) mean the extractor split one printed
  # row's stacked tax sub-rows into separate line items — the invoice-27
  # failure mode. One issue per invoice, not per line.
  defp lopsided_split_issues(invoice) do
    line_issue(invoice, "lopsided_tax_split", fn line ->
      is_nil(line["igst_amount"]) and
        is_nil(line["cgst_amount"]) != is_nil(line["sgst_amount"])
    end)
  end

  # One issue naming the 1-based line numbers a predicate matched, or none. Two
  # checks had written this out identically; the shape is the same every time
  # because the reviewer's question is the same every time — which rows?
  defp line_issue(invoice, code, predicate) do
    lines =
      (invoice["line_items"] || [])
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
    ([{"seller_gstin", invoice["seller_gstin"]}] ++
       if(is_nil(invoice["buyer_gstin"]),
         do: [],
         else: [{"buyer_gstin", invoice["buyer_gstin"]}]
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
    igst = sum(invoice["line_items"], "igst_amount")
    split = split_tax(invoice)

    if igst > 0 and split > 0 do
      [
        invoice
        |> issue(
          "mixed_tax_heads",
          "invoice carries both IGST (#{round2(igst)}) and CGST/SGST (#{round2(split)}) — one supply has one place of supply, so only one head can be correct",
          ["line_items"],
          Issues.level_for("mixed_tax_heads")
        )
        |> Map.merge(%{
          "tax_heads" => positive_tax_heads(invoice),
          "igst" => round2(igst),
          "split_tax" => round2(split)
        })
      ]
    else
      []
    end
  end

  defp split_tax(invoice),
    do: sum(invoice["line_items"], "cgst_amount") + sum(invoice["line_items"], "sgst_amount")

  defp positive_tax_heads(invoice) do
    [
      {"igst", sum(invoice["line_items"], "igst_amount")},
      {"cgst", sum(invoice["line_items"], "cgst_amount")},
      {"sgst", sum(invoice["line_items"], "sgst_amount")}
    ]
    |> Enum.filter(fn {_head, amount} -> amount > 0 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp consistency_issues(invoice) do
    seller_state = state_code(invoice["seller_gstin"])
    place_of_supply = effective_place_of_supply(invoice)
    place_field = if(invoice["place_of_supply"], do: "place_of_supply", else: "buyer_gstin")
    interstate? = seller_state && place_of_supply && seller_state != place_of_supply
    igst = sum(invoice["line_items"], "igst_amount")
    split = split_tax(invoice)

    cond do
      is_nil(seller_state) or is_nil(place_of_supply) ->
        []

      # Both heads present is `mixed_tax_heads`, which says something stronger
      # and does not depend on the GSTINs being right. Raising both would ask a
      # reviewer to answer the same malformed invoice twice.
      igst > 0 and split > 0 ->
        []

      interstate? and igst <= 0 and split > 0 ->
        [
          invoice
          |> issue(
            "tax_split_mismatch",
            "place of supply #{place_of_supply} differs from seller state #{seller_state}, but tax is CGST/SGST",
            [place_field, "line_items"],
            Issues.level_for("tax_split_mismatch")
          )
          |> Map.merge(%{
            "seller_state" => seller_state,
            "place_of_supply" => place_of_supply,
            "place_field" => place_field,
            "tax_heads" => positive_tax_heads(invoice)
          })
        ]

      not interstate? and split <= 0 and igst > 0 ->
        [
          invoice
          |> issue(
            "tax_split_mismatch",
            "place of supply #{place_of_supply} equals seller state #{seller_state}, but tax is IGST",
            [place_field, "line_items"],
            Issues.level_for("tax_split_mismatch")
          )
          |> Map.merge(%{
            "seller_state" => seller_state,
            "place_of_supply" => place_of_supply,
            "place_field" => place_field,
            "tax_heads" => positive_tax_heads(invoice)
          })
        ]

      true ->
        []
    end
  end

  defp line_tax_paise(line) do
    Money.paise(line["cgst_amount"]) + Money.paise(line["sgst_amount"]) +
      Money.paise(line["igst_amount"])
  end

  defp line_rate(line) do
    number(line["cgst_rate"]) + number(line["sgst_rate"]) + number(line["igst_rate"])
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

  defp paise(value) do
    case Money.paise_or_error(value) do
      {:ok, paise} -> paise
      _missing_or_unreadable -> nil
    end
  end

  defp add_paise(nil, _right), do: nil
  defp add_paise(left, right), do: left + right

  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp number(nil), do: 0
  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _unreadable -> 0
    end
  end

  defp num(value), do: number(value)

  defp rupee_number(%Decimal{} = paise),
    do: paise |> Decimal.div(100) |> Decimal.to_float()

  defp rupee_number(paise) when is_integer(paise), do: paise / 100
  defp round2(value), do: Float.round(value / 1, 2)
end
