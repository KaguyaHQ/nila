defmodule Nila.Gst.Sales.Gstr1 do
  @moduledoc """
  The pure GSTR-1 derivation + validation engine (the "brain").

  Takes normalized sales invoices and produces a portal-shaped GSTR-1 JSON
  (the artifact an auditor uploads), plus the deterministic validation issues
  and review-correction discipline the reproduction eval proved against real
  filed returns.

  This module is pure: no file IO, no network, no CLI. The dev eval runner
  (`scripts/gstr1_eval_lib.exs`) and the tests wrap it with fixture loading and
  scoring; the product wires it behind the sales extractor + worker. Ported from
  the original `scripts/gstr1_eval_lib.exs` reproduction harness.

  ## Public surface

    * `normalize_invoice/1` — raw extractor artifact → engine invoice map
    * `validation_issues/1` — deterministic issues (arithmetic, GSTIN checksum,
      state-vs-split, sequence gaps, poison totals) over normalized invoices
    * `flagged_fields/2` — the set of `(invoice, field)` a human may legitimately
      correct (low confidence or a validation issue)
    * `apply_corrections/3` — apply review corrections, separating flagged
      corrections from **silent errors** (corrections to unflagged fields)
    * `derive/2` — normalized invoices + filed header → portal GSTR-1 JSON
    * `valid_gstin?/1` — GSTIN mod-36 checksum

  Field-level diff/scoring of a derived return against a filed return is eval
  tooling, not product — the product never scores itself — so it lives in
  `scripts/gstr1_eval_lib.exs`, not here.
  """
  alias Nila.Gst.Purchase.Flags

  @confidence_threshold 0.90
  @money_tolerance 0.5
  @diff_tolerance 0.01
  @numeric_correction_field ~r/^(printed_total_taxable|printed_total_tax|printed_grand_total)$|\.(taxable_value|quantity|unit_price|[csi]gst_(rate|amount))$/

  @doc "Returns the flagged scalar fields that may be corrected for an invoice."
  def correctable_fields(flagged, pristine_invoice_number) do
    flagged
    |> Enum.filter(fn {invoice_number, field} ->
      invoice_number == pristine_invoice_number and field not in ["line_items", "doc_issue"] and
        not String.contains?(field, "confidence")
    end)
    |> Enum.map(fn {_invoice_number, field} -> field end)
    |> Enum.sort()
  end

  @doc "Reads a scalar invoice field, including `line_items[index].field` paths."
  def field_value(invoice, field_path) do
    case Regex.run(~r/^line_items\[(\d+)\]\.(.+)$/, field_path) do
      [_, index, line_field] ->
        line = Enum.at(invoice["line_items"], String.to_integer(index)) || %{}
        line[line_field]

      _ ->
        invoice[field_path]
    end
  end

  @doc "Coerces correction text for the numeric fields accepted by the review UI."
  def coerce_correction(field_path, text) do
    with true <- Regex.match?(@numeric_correction_field, field_path),
         {number, ""} <- Float.parse(text) do
      number
    else
      _ -> text
    end
  end

  @doc "Sums extracted taxable and tax amounts without deriving or rounding them."
  def extracted_totals(invoice) do
    Enum.reduce(List.wrap(invoice["line_items"]), %{taxable: 0, tax: 0}, fn line, totals ->
      %{
        taxable: totals.taxable + extracted_number(line["taxable_value"]),
        tax:
          totals.tax + extracted_number(line["cgst_amount"]) +
            extracted_number(line["sgst_amount"]) + extracted_number(line["igst_amount"])
      }
    end)
  end

  defp extracted_number(value) when is_number(value), do: value
  defp extracted_number(_value), do: 0

  def normalize_invoice(raw) when is_map(raw) do
    data = raw["data"] || raw["extract_result"] || raw["result"] || raw
    seller = data["seller"] || %{}
    buyer = data["buyer"] || data["bill_to"] || %{}

    line_items =
      data
      |> Map.get("line_items", [])
      |> Enum.map(&normalize_line/1)
      |> Enum.reject(&degenerate_line?/1)

    %{
      "page" => raw["page"] || data["page"],
      "source_pages" => raw["source_pages"] || [raw["page"] || data["page"]],
      "source_attribution" => raw["source_attribution"],
      "invoice_number" => normalize_invoice_number(value(data, ["invoice_number", "inum"])),
      "invoice_date" => value(data, ["invoice_date", "idt"]),
      "seller_name" => value(data, ["seller_name"]) || seller["name"],
      "seller_gstin" => value(data, ["seller_gstin"]) || seller["gstin"],
      "buyer_name" => value(data, ["buyer_name"]) || buyer["name"],
      "buyer_gstin" => value(data, ["buyer_gstin"]) || buyer["gstin"],
      "line_items" => line_items,
      "printed_total_taxable" =>
        money(value(data, ["printed_total_taxable", "total_net_amount"])),
      "printed_total_tax" => money(value(data, ["printed_total_tax", "total_tax_amount"])),
      "printed_grand_total" => money(value(data, ["printed_grand_total", "total_gross_amount"])),
      "confidence" => non_empty_map(raw["confidence"]) || build_confidence(raw)
    }
  end

  def validation_issues(invoices) do
    invoice_issues = Enum.flat_map(invoices, &invoice_issues/1)
    sequence_issues(invoices) ++ invoice_issues
  end

  def flagged_fields(invoices, issues) do
    low_conf =
      invoices
      |> Enum.flat_map(fn invoice ->
        confidence = invoice["confidence"] || %{}
        invoice_number = invoice["invoice_number"]

        confidence
        |> flatten_confidence()
        |> Enum.filter(fn {_field, value} ->
          is_number(value) and value < @confidence_threshold
        end)
        |> Enum.map(fn {field, _value} -> %{"invoice" => invoice_number, "field" => field} end)
      end)

    validation =
      issues
      |> Enum.reject(&(&1["level"] == "info"))
      |> Enum.flat_map(fn issue ->
        Enum.map(issue["fields"] || [], fn field ->
          %{"invoice" => issue["invoice"], "field" => field}
        end)
      end)

    MapSet.new(low_conf ++ validation, &flag_key/1)
  end

  @doc """
  Applies review corrections to normalized invoices.

  `corrections` is a decoded list of `%{"invoice", "field", "value"}` maps (the
  caller reads the patch file). A correction is legitimate only if its field was
  flagged; corrections to unflagged fields are **silent errors** — the
  trust-killing failure mode — and are collected separately.

  Returns `{final_invoices, flagged_corrections, silent_errors, flagged}`.
  """
  def apply_corrections(invoices, nil, flagged), do: {invoices, [], [], flagged}

  def apply_corrections(invoices, corrections, flagged) when is_list(corrections) do
    Enum.reduce(corrections, {invoices, [], [], flagged}, fn correction,
                                                             {acc, flagged_ok, silent, flags} ->
      invoice_number = correction["invoice"] || correction["inum"]

      updated =
        Enum.map(acc, fn invoice ->
          if invoice["invoice_number"] == invoice_number do
            put_field(invoice, correction["field"], correction["value"])
          else
            invoice
          end
        end)

      if correction_flagged?(flags, correction) do
        {updated, [correction | flagged_ok], silent, flags}
      else
        {updated, flagged_ok, [correction | silent], flags}
      end
    end)
  end

  @doc """
  The minimal production header for `derive/2` when there is no filed return —
  because the return is what we are producing. `derive/2` only reads
  gstin/fp/fil_dt from its second argument, so the client's own GSTIN and the
  filing period (stored "YYYY-MM", the portal's fp is "MMYYYY") suffice.
  """
  def production_header(gstin, period) do
    %{"gstin" => gstin, "fp" => portal_fp(period), "fil_dt" => nil}
  end

  defp portal_fp(period) do
    case String.split(period, "-") do
      [year, month] -> month <> year
      _ -> period
    end
  end

  def derive(invoices, filed) do
    seller_gstin = filed["gstin"] || first_present(invoices, "seller_gstin")
    seller_state = state_code(seller_gstin)

    b2b =
      invoices
      |> Enum.group_by(& &1["buyer_gstin"])
      |> Enum.map(fn {ctin, buyer_invoices} ->
        %{
          "ctin" => ctin,
          "inv" =>
            Enum.map(
              Enum.sort_by(buyer_invoices, &invoice_sort_key(&1["invoice_number"])),
              &derive_invoice(&1, seller_state)
            )
        }
      end)
      |> Enum.sort_by(& &1["ctin"])

    %{
      "gstin" => seller_gstin,
      "fp" => filed["fp"],
      "filing_typ" => filed["filing_typ"] || "M",
      "gt" => filed["gt"] || 0.0,
      "cur_gt" => filed["cur_gt"] || 0.0,
      "b2b" => b2b,
      "hsn" => %{"hsn_b2b" => derive_hsn(invoices), "hsn_b2c" => []},
      "doc_issue" => derive_doc_issue(invoices),
      "fil_dt" => filed["fil_dt"]
    }
  end

  defp normalize_line(line) do
    cgst = line["cgst"] || %{}
    sgst = line["sgst"] || %{}
    igst = line["igst"] || %{}

    %{
      "description" => line["description"],
      "hsn_sac" => to_string_or_nil(value(line, ["hsn_sac", "hsn_sc"])),
      "quantity" => money(value(line, ["quantity", "qty"])),
      "uom" => value(line, ["uom", "unit"]),
      "unit_price" => money(value(line, ["unit_price", "rate"])),
      "taxable_value" => money(value(line, ["taxable_value", "taxable", "net_amount", "txval"])),
      "cgst_rate" => money(line["cgst_rate"] || cgst["rate"]),
      "cgst_amount" => money(line["cgst_amount"] || cgst["amount"] || line["camt"]),
      "sgst_rate" => money(line["sgst_rate"] || sgst["rate"]),
      "sgst_amount" => money(line["sgst_amount"] || sgst["amount"] || line["samt"]),
      "igst_rate" => money(line["igst_rate"] || igst["rate"]),
      "igst_amount" => money(line["igst_amount"] || igst["amount"] || line["iamt"])
    }
  end

  defp invoice_issues(invoice) do
    line_issues =
      invoice["line_items"]
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, index} -> line_issues(invoice, line, index) end)

    invoice_number_issues(invoice) ++
      arithmetic_issues(invoice) ++
      gstin_issues(invoice) ++
      consistency_issues(invoice) ++
      lopsided_split_issues(invoice) ++
      furniture_row_issues(invoice) ++ bucket_rounding_issues(invoice) ++ line_issues
  end

  defp invoice_number_issues(invoice) do
    smell =
      Flags.invoice_number_smell(invoice["invoice_number"], sales_invoice_has_values?(invoice))

    case smell do
      nil ->
        []

      :phone_number ->
        [
          issue(
            invoice,
            "implausible_invoice_number",
            "invoice number #{invoice["invoice_number"]} looks like a phone number — verify it against the bill",
            ["invoice_number"]
          )
        ]

      :date ->
        [
          issue(
            invoice,
            "implausible_invoice_number",
            "invoice number #{invoice["invoice_number"]} looks like a date — verify it against the bill",
            ["invoice_number"]
          )
        ]

      :missing ->
        [
          issue(
            invoice,
            "implausible_invoice_number",
            "the invoice carries values but no invoice number was extracted — verify it against the bill",
            ["invoice_number"]
          )
        ]
    end
  end

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
    furniture_rows =
      invoice["line_items"]
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _index} ->
        furniture_description?(line["description"]) and not degenerate_line?(line)
      end)
      |> Enum.map(fn {_line, index} -> index end)

    if furniture_rows == [] do
      []
    else
      [
        issue(
          invoice,
          "furniture_row_with_values",
          "furniture rows #{Enum.join(furniture_rows, ", ")} carry taxable/tax values — keep for review, do not silently drop",
          ["line_items"]
        )
      ]
    end
  end

  defp bucket_rounding_issues(invoice) do
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
            "info"
          )
        ]

      true ->
        [
          issue(
            invoice,
            "bucket_tax_mismatch",
            "#{field} line-tax sum #{round2(extracted)} differs from bucket taxable × #{rate}% #{round2(computed)} by #{delta}, beyond per-line rounding bound",
            ["line_items"]
          )
        ]
    end
  end

  defp rounding_variance_bound(lines), do: 0.005 * length(lines) + 0.000001

  defp line_issues(invoice, line, index) do
    taxable = num(line["taxable_value"])
    tax = num(line["cgst_amount"]) + num(line["sgst_amount"]) + num(line["igst_amount"])
    rate = num(line["cgst_rate"]) + num(line["sgst_rate"]) + num(line["igst_rate"])
    expected_tax = taxable * rate / 100

    if close?(tax, expected_tax, @money_tolerance) do
      []
    else
      [
        issue(
          invoice,
          "line_arithmetic",
          "line #{index} tax #{tax} does not match #{taxable} × #{rate}% = #{round2(expected_tax)}",
          [
            "line_items[#{index - 1}].taxable_value",
            "line_items[#{index - 1}].cgst_amount",
            "line_items[#{index - 1}].sgst_amount",
            "line_items[#{index - 1}].igst_amount"
          ]
        )
      ]
    end
  end

  # A real intra-state line always carries both CGST and SGST. Lines with
  # exactly one of them (and no IGST) mean the extractor split one printed
  # row's stacked tax sub-rows into separate line items — the invoice-27
  # failure mode. One issue per invoice, not per line.
  defp lopsided_split_issues(invoice) do
    lopsided =
      invoice["line_items"]
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _index} ->
        is_nil(line["igst_amount"]) and
          is_nil(line["cgst_amount"]) != is_nil(line["sgst_amount"])
      end)
      |> Enum.map(fn {_line, index} -> index end)

    if lopsided == [] do
      []
    else
      [
        issue(
          invoice,
          "lopsided_tax_split",
          "lines #{Enum.join(lopsided, ", ")} carry only one of CGST/SGST — stacked tax sub-rows were likely split into separate line items",
          ["line_items"]
        )
      ]
    end
  end

  defp arithmetic_issues(invoice) do
    taxable = invoice_taxable(invoice)
    tax = invoice_tax(invoice)
    grand = taxable + tax

    [
      maybe_issue(
        invoice,
        "printed_taxable_mismatch",
        invoice["printed_total_taxable"],
        taxable,
        "printed taxable total does not match line taxable sum",
        ["printed_total_taxable", "line_items"]
      ),
      maybe_issue(
        invoice,
        "printed_tax_mismatch",
        invoice["printed_total_tax"],
        tax,
        "printed tax total does not match line tax sum",
        ["printed_total_tax", "line_items"]
      ),
      maybe_issue(
        invoice,
        "grand_total_mismatch",
        invoice["printed_grand_total"],
        grand,
        "printed grand total does not match line taxable + tax",
        ["printed_grand_total", "line_items"]
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp gstin_issues(invoice) do
    [
      {"seller_gstin", invoice["seller_gstin"]},
      {"buyer_gstin", invoice["buyer_gstin"]}
    ]
    |> Enum.flat_map(fn {field, gstin} ->
      if valid_gstin?(gstin) do
        []
      else
        [
          issue(invoice, "invalid_gstin", "#{field} #{inspect(gstin)} fails GSTIN checksum", [
            field
          ])
        ]
      end
    end)
  end

  defp consistency_issues(invoice) do
    seller_state = state_code(invoice["seller_gstin"])
    buyer_state = state_code(invoice["buyer_gstin"])
    interstate? = seller_state && buyer_state && seller_state != buyer_state
    igst = invoice["line_items"] |> Enum.map(&num(&1["igst_amount"])) |> Enum.sum()

    split =
      invoice["line_items"]
      |> Enum.map(&(num(&1["cgst_amount"]) + num(&1["sgst_amount"])))
      |> Enum.sum()

    cond do
      is_nil(seller_state) or is_nil(buyer_state) ->
        []

      interstate? and igst <= 0 and split > 0 ->
        [
          issue(
            invoice,
            "tax_split_mismatch",
            "buyer state #{buyer_state} differs from seller state #{seller_state}, but tax is CGST/SGST",
            ["buyer_gstin", "line_items"]
          )
        ]

      not interstate? and split <= 0 and igst > 0 ->
        [
          issue(
            invoice,
            "tax_split_mismatch",
            "buyer state #{buyer_state} equals seller state #{seller_state}, but tax is IGST",
            ["buyer_gstin", "line_items"]
          )
        ]

      true ->
        []
    end
  end

  defp sequence_issues(invoices) do
    parsed =
      invoices
      |> Enum.map(&parse_invoice_number(&1["invoice_number"]))
      |> Enum.reject(&is_nil/1)

    case parsed do
      [] ->
        []

      parsed ->
        numbers = Enum.map(parsed, & &1.number)
        min = Enum.min(numbers)
        max = Enum.max(numbers)
        missing = Enum.to_list(min..max) -- numbers

        if missing == [] do
          []
        else
          suffix = parsed |> hd() |> Map.fetch!(:suffix)

          [
            %{
              "invoice" => nil,
              "code" => "sequence_gaps",
              "message" =>
                "missing/cancelled inferred from sequence: #{Enum.map_join(missing, ", ", &"#{&1}#{suffix}")} — confirm cancellation records",
              "fields" => ["doc_issue"]
            }
          ]
        end
    end
  end

  defp maybe_issue(_invoice, _code, nil, _expected, _message, _fields), do: nil

  defp maybe_issue(invoice, code, actual, expected, message, fields) do
    if close?(num(actual), expected, @money_tolerance) do
      nil
    else
      issue(
        invoice,
        code,
        "#{message}: printed #{round2(num(actual))}, derived #{round2(expected)}",
        fields
      )
    end
  end

  defp issue(invoice, code, message, fields, level \\ nil) do
    %{
      "invoice" => invoice["invoice_number"],
      "code" => code,
      "message" => message,
      "fields" => fields
    }
    |> maybe_put_level(level)
  end

  defp maybe_put_level(issue, nil), do: issue
  defp maybe_put_level(issue, level), do: Map.put(issue, "level", level)

  defp derive_invoice(invoice, seller_state) do
    buyer_state = state_code(invoice["buyer_gstin"])
    lines_by_rate = Enum.group_by(invoice["line_items"], &line_rate/1)

    itms =
      lines_by_rate
      |> Enum.sort_by(fn {rate, _lines} -> rate end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{rate, lines}, index} ->
        tax = computed_bucket_tax(lines, rate, invoice_tax_mode(lines, seller_state, buyer_state))

        %{
          "num" => index,
          "itm_det" => %{
            "rt" => normalize_number(rate),
            "txval" => tax.txval,
            "camt" => tax.camt,
            "samt" => tax.samt,
            "iamt" => tax.iamt,
            "csamt" => 0
          }
        }
      end)

    taxable = invoice_taxable(invoice)
    tax = invoice_tax(invoice)

    %{
      "inum" => invoice["invoice_number"],
      "idt" => normalize_date(invoice["invoice_date"]),
      "val" => round2(taxable + tax),
      "pos" => buyer_state || seller_state,
      "rchrg" => "N",
      "inv_typ" => "R",
      "itms" => itms
    }
  end

  defp derive_hsn(invoices) do
    invoices
    |> Enum.flat_map(& &1["line_items"])
    |> Enum.group_by(fn line -> {hsn4(line["hsn_sac"]), line_rate(line)} end)
    |> Enum.map(fn {{hsn, rate}, lines} ->
      intra_tax =
        computed_bucket_tax(Enum.filter(lines, &(tax_mode(&1) == :intrastate)), rate, :intrastate)

      inter_tax =
        computed_bucket_tax(Enum.filter(lines, &(tax_mode(&1) == :interstate)), rate, :interstate)

      %{
        "hsn_sc" => hsn,
        "rt" => normalize_number(rate),
        "uqc" => if(String.starts_with?(to_string(hsn), "99"), do: "NA", else: "OTH"),
        "qty" => 0,
        "txval" => round2(sum(lines, "taxable_value")),
        "camt" => intra_tax.camt,
        "samt" => intra_tax.samt,
        "iamt" => inter_tax.iamt
      }
    end)
    |> Enum.sort_by(& &1["hsn_sc"])
    |> Enum.with_index(1)
    |> Enum.map(fn {row, index} -> Map.put(row, "num", index) end)
  end

  defp derive_doc_issue(invoices) do
    invoices
    |> Enum.map(&parse_invoice_number(&1["invoice_number"]))
    |> Enum.reject(&is_nil/1)
    |> build_doc_issue()
  end

  # No parseable invoice numbers (empty month, or none numeric) means nothing
  # was issued — a valid return with an empty doc_det, not a crash.
  defp build_doc_issue([]), do: %{"doc_det" => []}

  defp build_doc_issue(parsed) do
    numbers = Enum.map(parsed, & &1.number)
    min = Enum.min(numbers)
    max = Enum.max(numbers)
    suffix = parsed |> hd() |> Map.fetch!(:suffix)
    totnum = max - min + 1
    net_issue = length(Enum.uniq(numbers))

    %{
      "doc_det" => [
        %{
          "doc_num" => 1,
          "docs" => [
            %{
              "num" => 1,
              "from" => "#{min}#{suffix}",
              "to" => "#{max}#{suffix}",
              "totnum" => totnum,
              "cancel" => totnum - net_issue,
              "net_issue" => net_issue
            }
          ]
        }
      ]
    }
  end

  defp put_field(invoice, field, value) do
    case Regex.run(~r/^line_items\[(\d+)\]\.(.+)$/, field || "") do
      [_, index, line_field] ->
        index = String.to_integer(index)

        update_in(invoice, ["line_items", Access.at(index)], fn line ->
          Map.put(line || %{}, line_field, value)
        end)

      _ ->
        Map.put(invoice, field, value)
    end
  end

  defp close?(a, b, tolerance), do: abs(num(a) - num(b)) <= tolerance + 0.000001

  defp invoice_taxable(invoice), do: sum(invoice["line_items"], "taxable_value")

  defp invoice_tax(invoice) do
    invoice["line_items"]
    |> Enum.group_by(&line_rate/1)
    |> Enum.map(fn {rate, lines} ->
      lines
      |> Enum.group_by(&tax_mode/1)
      |> Enum.map(fn {mode, mode_lines} ->
        tax = computed_bucket_tax(mode_lines, rate, mode)
        tax.camt + tax.samt + tax.iamt
      end)
      |> Enum.sum()
    end)
    |> Enum.sum()
  end

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

  defp invoice_tax_mode(lines, seller_state, buyer_state) do
    cond do
      seller_state && buyer_state && seller_state != buyer_state -> :interstate
      seller_state && buyer_state -> :intrastate
      true -> tax_mode(List.first(lines) || %{})
    end
  end

  defp tax_mode(line) do
    if num(line["igst_amount"]) > 0 or num(line["igst_rate"]) > 0 do
      :interstate
    else
      :intrastate
    end
  end

  defp sum(lines, field), do: lines |> Enum.map(&num(&1[field])) |> Enum.sum()

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

  defp line_rate(line),
    do: num(line["cgst_rate"]) + num(line["sgst_rate"]) + num(line["igst_rate"])

  defp normalize_date(nil), do: nil

  defp normalize_date(date) do
    date
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[.\/]/, "-")
  end

  defp hsn4(nil), do: nil
  defp hsn4(hsn), do: hsn |> to_string() |> String.replace(~r/\D/, "") |> String.slice(0, 4)

  defp normalize_invoice_number(nil), do: nil

  defp normalize_invoice_number(invoice_number) do
    invoice_number
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s*\/\s*/, "/")
  end

  defp parse_invoice_number(nil), do: nil

  defp parse_invoice_number(invoice_number) do
    case Regex.run(~r/^(\d+)(.*)$/, normalize_invoice_number(invoice_number)) do
      [_, number, suffix] -> %{number: String.to_integer(number), suffix: suffix}
      _ -> nil
    end
  end

  defp invoice_sort_key(invoice_number) do
    case parse_invoice_number(invoice_number) do
      %{number: number} -> number
      nil -> 999_999
    end
  end

  def valid_gstin?(gstin) when is_binary(gstin) do
    gstin = String.upcase(String.trim(gstin))

    if String.match?(gstin, ~r/^\d{2}[A-Z0-9]{13}$/) and String.length(gstin) == 15 do
      body = String.slice(gstin, 0, 14)
      expected = gstin_check_digit(body)
      String.at(gstin, 14) == expected
    else
      false
    end
  end

  def valid_gstin?(_), do: false

  defp gstin_check_digit(body) do
    chars = String.graphemes(body)

    sum =
      chars
      |> Enum.with_index()
      |> Enum.reduce(0, fn {char, index}, acc ->
        product = base36_value(char) * if(rem(index, 2) == 0, do: 1, else: 2)
        acc + div(product, 36) + rem(product, 36)
      end)

    check = rem(36 - rem(sum, 36), 36)
    base36_char(check)
  end

  defp base36_value(<<char>>) when char in ?0..?9, do: char - ?0
  defp base36_value(<<char>>) when char in ?A..?Z, do: char - ?A + 10
  defp base36_char(value) when value < 10, do: <<?0 + value>>
  defp base36_char(value), do: <<?A + value - 10>>

  defp state_code(nil), do: nil

  defp state_code(gstin) do
    gstin = to_string(gstin)

    if String.length(gstin) >= 2 do
      String.slice(gstin, 0, 2)
    end
  end

  defp money(nil), do: nil
  defp money(value) when is_number(value), do: value

  defp money(value) when is_binary(value) do
    value = value |> String.replace(",", "") |> String.replace(~r/[^0-9.\-]/, "")

    case Float.parse(value) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp num(nil), do: 0
  defp num(value) when is_integer(value), do: value / 1
  defp num(value) when is_float(value), do: value
  defp num(value) when is_binary(value), do: money(value) || 0

  defp round2(value), do: Float.round(num(value), 2)

  defp normalize_number(value) do
    value = round2(value)

    if value == trunc(value) / 1 do
      trunc(value)
    else
      value
    end
  end

  defp value(map, keys), do: Enum.find_value(keys, &map[&1])

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp first_present(invoices, field), do: Enum.find_value(invoices, & &1[field])

  defp build_confidence(raw) do
    non_empty_map(get_in(raw, ["extract_metadata", "field_metadata", "document_metadata"])) || %{}
  end

  defp non_empty_map(value) when is_map(value) and map_size(value) > 0, do: value
  defp non_empty_map(_), do: nil

  defp flatten_confidence(map, prefix \\ nil) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      field = if prefix, do: "#{prefix}.#{key}", else: key

      cond do
        is_map(value) and is_number(value["confidence"]) -> [{field, value["confidence"]}]
        is_map(value) -> flatten_confidence(value, field)
        is_list(value) -> flatten_list_confidence(value, field)
        is_number(value) -> [{field, value}]
        true -> []
      end
    end)
  end

  defp flatten_list_confidence(values, prefix) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      if is_map(value), do: flatten_confidence(value, "#{prefix}[#{index}]"), else: []
    end)
  end

  defp correction_flagged?(flags, correction) do
    invoice = correction["invoice"] || correction["inum"]
    field = correction["field"]

    MapSet.member?(flags, {invoice, field}) ||
      Enum.any?(flags, fn
        {^invoice, flagged_field} when is_binary(flagged_field) and is_binary(field) ->
          field == flagged_field or String.starts_with?(field, flagged_field <> "[") or
            String.starts_with?(field, flagged_field <> ".")

        _ ->
          false
      end)
  end

  defp flag_key(%{"invoice" => invoice, "field" => field}), do: {invoice, field}
  defp flag_key(%{"inum" => invoice, "field" => field}), do: {invoice, field}
end
