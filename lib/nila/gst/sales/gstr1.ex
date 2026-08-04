defmodule Nila.Gst.Sales.Gstr1 do
  @moduledoc """
  The pure GSTR-1 derivation + validation engine (the "brain").

  Takes normalized sales invoices and produces a portal-shaped GSTR-1 JSON
  (the artifact an auditor uploads), plus the deterministic validation issues
  and review-correction discipline the reproduction eval proved against real
  filed returns.

  This module is pure: no file IO, no network, no CLI. `Nila.Eval` wraps it with
  artifact loading and scoring; the product wires it behind the sales extractor
  + worker.

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
  `Nila.Eval.Gstr1Diff`, not here.
  """
  alias Nila.Gst.InvoiceNumber
  alias Nila.Gst.Issues
  alias Nila.Gst.Purchase.Books
  alias Nila.Gst.Purchase.Flags

  @confidence_threshold 0.90
  @money_tolerance 0.5
  @diff_tolerance 0.01
  @correctable_invoice_fields ~w(
    invoice_number invoice_date seller_name seller_gstin buyer_name buyer_gstin
    printed_total_taxable printed_total_tax printed_grand_total
  )
  @correctable_line_fields ~w(
    description hsn_sac quantity uom unit_price taxable_value
    cgst_rate cgst_amount sgst_rate sgst_amount igst_rate igst_amount
  )
  @numeric_correction_field ~r/^(printed_total_taxable|printed_total_tax|printed_grand_total)$|\.(taxable_value|quantity|unit_price|[csi]gst_(rate|amount))$/

  @doc "Returns the flagged scalar fields that may be corrected for a source invoice."
  def correctable_fields(flagged, pristine_source_id) do
    flagged
    |> Enum.filter(fn {source_id, field} ->
      source_id == pristine_source_id and correctable_field?(field)
    end)
    |> Enum.map(fn {_source_id, field} -> field end)
    |> Enum.sort()
  end

  @doc "Whether a path names a business field the review flow may edit."
  def correctable_field?(field) when field in @correctable_invoice_fields, do: true

  def correctable_field?(field) when is_binary(field) do
    case parse_field_path(field) do
      {:line, _index, line_field} -> line_field in @correctable_line_fields
      {:invoice, _field} -> false
    end
  end

  def correctable_field?(_field), do: false

  @doc "Whether a flagged correction is authorized for a source invoice and field path."
  def correction_allowed?(flagged, source_id, field) do
    correctable_field?(field) and
      (MapSet.member?(flagged, {source_id, field}) or
         Enum.any?(flagged, fn
           {^source_id, flagged_field}
           when is_binary(flagged_field) and is_binary(field) ->
             String.starts_with?(field, flagged_field <> "[") or
               String.starts_with?(field, flagged_field <> ".")

           _ ->
             false
         end))
  end

  @doc "Stable source identity when present, otherwise the legacy invoice-number identity."
  def source_id(invoice), do: invoice["id"] || invoice["invoice_number"]

  @doc "Reads a scalar invoice field, including `line_items[index].field` paths."
  def field_value(invoice, field_path) do
    case parse_field_path(field_path) do
      {:line, index, line_field} ->
        line = Enum.at(invoice["line_items"] || [], index) || %{}
        line[line_field]

      {:invoice, field} ->
        invoice[field]
    end
  end

  # The one reading of a correction's field path. It was written out three
  # times — twice with a capture group and once without, and only one of the
  # three tolerated a nil path, so `field_value/2` raised on input the sibling
  # writer accepted.
  defp parse_field_path(field_path) do
    case Regex.run(~r/^line_items\[(\d+)\]\.(.+)$/, field_path || "") do
      [_, index, line_field] -> {:line, String.to_integer(index), line_field}
      _not_a_line_path -> {:invoice, field_path}
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
      "invoice_date" => normalize_invoice_date(value(data, ["invoice_date", "idt"])),
      "seller_name" => value(data, ["seller_name"]) || seller["name"],
      "seller_gstin" => value(data, ["seller_gstin"]) || seller["gstin"],
      "buyer_name" => value(data, ["buyer_name"]) || buyer["name"],
      "buyer_gstin" => value(data, ["buyer_gstin"]) || buyer["gstin"],
      "line_items" => line_items,
      "printed_total_taxable" =>
        money(value(data, ["printed_total_taxable", "total_net_amount"])),
      "printed_total_tax" => money(value(data, ["printed_total_tax", "total_tax_amount"])),
      "printed_grand_total" => money(value(data, ["printed_grand_total", "total_gross_amount"])),
      "confidence" => non_empty_map(raw["confidence"]) || build_confidence(raw),
      "document" => raw["document"] || %{}
    }
  end

  def validation_issues(invoices) do
    invoice_issues = Enum.flat_map(invoices, &invoice_issues/1)
    sequence_issues(invoices) ++ invoice_issues
  end

  @doc """
  Issues that must be answered before a GSTR-1 can be signed, not merely read.

  `derive/2` builds `b2b`, `hsn` and `doc_issue` and nothing else, which is
  exactly what both clients have filed in every month of the corpus. A document
  that belongs in a table this return does not have would still be derived — as
  a *regular outward supply*, because that is the only shape on offer. A credit
  note would be filed as a sale of the same value, so the liability moves by
  twice its amount in the wrong direction; an export or SEZ supply would be
  filed as taxable; a reverse-charge supply would be filed `rchrg: "N"` and the
  tax charged to the wrong party.

  None of these can be caught downstream: every one is arithmetically perfect.
  So the return refuses to be signed while one is present, and the missing table
  gets built when a real document asks for it rather than from imagination.
  """
  def blocking_issues(invoices) do
    Enum.flat_map(invoices, &unsupported_document_issues/1) ++ duplicate_number_issues(invoices)
  end

  @doc "One blocking issue per duplicate active invoice-number group."
  def duplicate_number_issues(invoices) do
    invoices
    |> Enum.filter(&(is_binary(&1["invoice_number"]) and String.trim(&1["invoice_number"]) != ""))
    # Grouped on the matching key, not the printed string: `inv/1` and `INV/1`
    # are one invoice issued twice, and grouping on the raw text let the pair
    # through as two. The message still names the number as it was read.
    |> Enum.group_by(&InvoiceNumber.key(&1["invoice_number"]))
    |> Enum.filter(fn {_key, members} -> length(members) > 1 end)
    |> Enum.map(fn {_key, members} ->
      invoice_number = members |> hd() |> Map.fetch!("invoice_number")
      source_ids = members |> Enum.map(&source_id/1) |> Enum.sort()

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

  defp unsupported_document_issues(invoice) do
    document = invoice["document"] || %{}

    [
      {document["credit_note"], "credit_note_unsupported",
       "this is a credit note, and GSTR-1 derivation has no cdnr table — filing it as a regular invoice would move the liability by twice its value"},
      {document["debit_note"], "debit_note_unsupported",
       "this is a debit note, and GSTR-1 derivation has no cdnr table"},
      {document["export"], "export_supply_unsupported",
       "this bill carries export, LUT or SEZ wording, and GSTR-1 derivation has no exp table — it would be filed as an ordinary taxable supply"},
      {document["reverse_charge"], "outward_reverse_charge_unsupported",
       "this bill says the recipient pays the tax, and derivation files every invoice rchrg \"N\""},
      {is_nil(invoice["buyer_gstin"]), "b2c_supply_unsupported",
       "no buyer GSTIN, and GSTR-1 derivation has no b2cs table — it would be grouped under a null ctin in b2b"}
    ]
    |> Enum.filter(fn {present?, _code, _message} -> present? == true end)
    |> Enum.map(fn {_present?, code, message} ->
      issue(invoice, code, message, ["invoice_number"], Issues.level_for(code))
    end)
  end

  def flagged_fields(invoices, issues) do
    low_conf =
      invoices
      |> Enum.flat_map(fn invoice ->
        confidence = invoice["confidence"] || %{}
        source_id = source_id(invoice)

        confidence
        |> flatten_confidence()
        |> Enum.filter(fn {_field, value} ->
          is_number(value) and value < @confidence_threshold
        end)
        |> Enum.map(fn {field, _value} -> %{"source_id" => source_id, "field" => field} end)
      end)

    validation =
      issues
      |> Enum.reject(&(Issues.level(&1) == "info"))
      |> Enum.flat_map(fn issue ->
        # `source_ids` means the named fields apply equally to every member of
        # one source group; today only duplicate-number issues carry it.
        source_ids = issue["source_ids"] || [issue["source_id"] || issue["invoice"]]

        for source_id <- source_ids,
            field <- issue["fields"] || [],
            do: %{"source_id" => source_id, "field" => field}
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
      target = correction_target(acc, correction)

      updated =
        Enum.map(acc, fn invoice ->
          if target && source_id(invoice) == target do
            put_field(invoice, correction["field"], correction["value"])
          else
            invoice
          end
        end)

      if target && correction_allowed?(flags, target, correction["field"]) do
        {updated, [correction | flagged_ok], silent, flags}
      else
        {updated, flagged_ok, [correction | silent], flags}
      end
    end)
  end

  @doc """
  The minimal production header for `derive/2` when there is no filed return —
  because the return is what we are producing. The client's own GSTIN and the
  filing period (stored "YYYY-MM", the portal's fp is "MMYYYY") are what we can
  know without one.

  `derive/2` reads six keys from its second argument, not three: `gstin`, `fp`,
  `filing_typ`, `gt`, `cur_gt` and `fil_dt`. This header supplies gstin/fp/fil_dt
  and lets the other three take their fallbacks (`"M"`, `0.0`, `0.0`) — correct,
  because a monthly filing is the default and the turnover figures are portal
  bookkeeping we do not derive. `mix nila.eval bridge --header production` is the
  control that keeps this honest: it re-scores every month with this header and
  must reproduce the same numbers as the filed one.
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
    check_issues =
      invoice
      |> invoice_checks()
      |> Enum.reject(& &1["passed"])
      |> failed_check_issues(invoice)

    invoice_number_issues(invoice) ++
      invoice_date_issues(invoice) ++
      check_issues ++
      gstin_issues(invoice) ++
      mixed_head_issues(invoice) ++
      consistency_issues(invoice) ++
      lopsided_split_issues(invoice) ++
      furniture_row_issues(invoice) ++ bucket_rounding_issues(invoice)
  end

  @doc """
  Arithmetic check outcomes for one invoice — passed and failed alike, each with
  the operands a screen can print (`15,200 × 18% = 2,736 ✓`).

  This is the sole judge of these checks: `validation_issues/1` raises the
  failing subset and nothing else (`failed_check_issues/2`), and the invoice
  modal renders outcomes without computing anything, so a ✓ can never sit beside
  an open issue for the same check. A check only exists where the bill makes a
  claim — a furniture row with no values, or an absent printed total, yields no
  outcome rather than a vacuous pass.

  Failures outnumber issues, because an issue is a resolution target: the
  failing lines of one check collapse into one issue, and a bill total that is
  out by exactly what its components are out by is folded into theirs. Every
  failure still prints its own ✗ with its own operands; what it no longer gets
  is its own card and its own button.
  """
  def invoice_checks(invoice) do
    line_arithmetic_checks(invoice) ++
      split_equality_checks(invoice) ++ printed_total_checks(invoice)
  end

  defp line_arithmetic_checks(invoice) do
    invoice["line_items"]
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, index} ->
      taxable = num(line["taxable_value"])
      tax = num(line["cgst_amount"]) + num(line["sgst_amount"]) + num(line["igst_amount"])
      rate = num(line["cgst_rate"]) + num(line["sgst_rate"]) + num(line["igst_rate"])

      if taxable == 0 and tax == 0 and rate == 0 do
        []
      else
        [
          %{
            "code" => "line_arithmetic",
            "line" => index,
            "operands" => %{
              "taxable" => taxable,
              "rate" => rate,
              "expected" => taxable * rate / 100,
              "actual" => tax
            },
            "passed" => close?(tax, taxable * rate / 100, @money_tolerance),
            "fields" => [
              "line_items[#{index - 1}].taxable_value",
              "line_items[#{index - 1}].cgst_amount",
              "line_items[#{index - 1}].sgst_amount",
              "line_items[#{index - 1}].igst_amount"
            ]
          }
        ]
      end
    end)
  end

  # CGST and SGST are equal halves of one levy by construction; a line whose
  # halves differ passed no other check (`line_arithmetic` sums them, so a
  # high-low pair can still multiply out) and is exactly the kind of quiet
  # extraction error the modal exists to surface.
  defp split_equality_checks(invoice) do
    invoice["line_items"]
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, index} ->
      if is_number(line["cgst_amount"]) and is_number(line["sgst_amount"]) do
        [
          %{
            "code" => "cgst_sgst_unequal",
            "line" => index,
            "operands" => %{
              "cgst" => num(line["cgst_amount"]),
              "sgst" => num(line["sgst_amount"])
            },
            "passed" =>
              close?(num(line["cgst_amount"]), num(line["sgst_amount"]), @money_tolerance),
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
    taxable = invoice_taxable(invoice)
    tax = invoice_tax(invoice)

    [
      {"printed_taxable_mismatch", invoice["printed_total_taxable"], taxable,
       ["printed_total_taxable", "line_items"]},
      {"printed_tax_mismatch", invoice["printed_total_tax"], tax,
       ["printed_total_tax", "line_items"]},
      {"grand_total_mismatch", invoice["printed_grand_total"], taxable + tax,
       ["printed_grand_total", "line_items"]}
    ]
    |> Enum.flat_map(fn
      {_code, nil, _derived, _fields} ->
        []

      {code, printed, derived, fields} ->
        [
          %{
            "code" => code,
            "operands" => %{"printed" => num(printed), "derived" => derived},
            "passed" => close?(num(printed), derived, @money_tolerance),
            "fields" => fields
          }
        ]
    end)
  end

  @printed_total_codes ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch)

  # The failing checks as the issues a reviewer answers, which is fewer rows than
  # there are failures.
  #
  # Two collapses, both because a row is a resolution target and a target is not
  # a line. Per-line checks share `source_id:code`, so three lines that do not
  # multiply out were three cards posting one answer, and a count that fell by
  # three when one was given. And the printed totals are not three independent
  # claims: the grand total is *defined* as taxable + tax, so a single misread
  # figure trips two or three of them at once. Where the bill total is out by
  # exactly what the components are out by, it is the same misreading told twice,
  # and it says so inside the one card rather than opening its own.
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
      checks |> Enum.flat_map(& &1["fields"]) |> Enum.uniq(),
      Issues.level_for(code)
    )
    |> Map.put("lines", Enum.map(checks, & &1["line"]))
  end

  defp printed_total_issues(_invoice, []), do: []

  defp printed_total_issues(invoice, failed) do
    {grand, components} = Enum.split_with(failed, &(&1["code"] == "grand_total_mismatch"))

    if components != [] and grand_total_explained?(invoice, grand) do
      # The grand total is taxable + tax by definition, so once the components
      # account for it, it is not a third finding and gets folded in.
      #
      # The components themselves are NOT folded into each other. A printed
      # taxable total and a printed tax total are two different figures and two
      # different misreadings, and merging them destroys a resolution target:
      # the survivor took the first component's code, so a confirmation given
      # about the taxable total silently marked the tax total answered by
      # somebody who was never asked about it.
      Enum.map(components, &collapsed_printed_issue(invoice, &1, grand))
    else
      Enum.map(failed, &check_issue(invoice, &1))
    end
  end

  # A printed component that is absent explains nothing and needs no explaining,
  # so it contributes no difference: if the bill prints a taxable total and a
  # grand total and both are out by the same amount, the tax portion of the grand
  # total agreed with the lines, which is exactly the evidence of one cause.
  defp grand_total_explained?(_invoice, []), do: false

  defp grand_total_explained?(invoice, [%{"operands" => ops}]) do
    explained =
      printed_delta(invoice["printed_total_taxable"], invoice_taxable(invoice)) +
        printed_delta(invoice["printed_total_tax"], invoice_tax(invoice))

    close?(ops["printed"] - ops["derived"], explained, 2 * @money_tolerance)
  end

  defp printed_delta(nil, _derived), do: 0
  defp printed_delta(printed, derived), do: num(printed) - derived

  defp collapsed_printed_issue(invoice, %{"code" => code} = component, [grand]) do
    ops = grand["operands"]

    message =
      check_message(component) <>
        " — and the printed bill total, which is taxable + tax, is out by exactly that much " <>
        "(printed #{round2(ops["printed"])}, derived #{round2(ops["derived"])})"

    issue(
      invoice,
      code,
      message,
      [component, grand] |> Enum.flat_map(& &1["fields"]) |> Enum.uniq(),
      Issues.level_for(code)
    )
  end

  defp check_issue(invoice, %{"code" => code, "fields" => fields} = check) do
    issue(invoice, code, check_message(check), fields, Issues.level_for(code))
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

  # The date is the one field that reaches the portal with nothing downstream
  # comparing it, so without this it files whatever the model printed.
  #
  # Asks whether the value *is* a date, not whether it is a `Date`: an invoice
  # read back out of JSONB carries the ISO string, and a check keyed on the
  # struct would flag every stored invoice in the product. Anything that is not
  # a date — a bare number the schema asked to be a string, a caption, a blank —
  # is flagged rather than let through, because each of those is also invisible
  # to the precondition checks, which match on `Date`.
  #
  # Gated on the invoice carrying values, the same gate `invoice_number_issues/1`
  # uses: a furniture row scraped off a page header is not a bill anyone files.
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
      Flags.invoice_number_smell(invoice["invoice_number"], sales_invoice_has_values?(invoice))

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
          issue(
            invoice,
            code,
            line_issue_message(code, lines),
            ["line_items"],
            Issues.level_for(code)
          )
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
    [
      {"seller_gstin", invoice["seller_gstin"]},
      {"buyer_gstin", invoice["buyer_gstin"]}
    ]
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
        issue(
          invoice,
          "mixed_tax_heads",
          "invoice carries both IGST (#{round2(igst)}) and CGST/SGST (#{round2(split)}) — one supply has one place of supply, so only one head can be correct",
          ["line_items"],
          Issues.level_for("mixed_tax_heads")
        )
      ]
    else
      []
    end
  end

  defp split_tax(invoice),
    do: sum(invoice["line_items"], "cgst_amount") + sum(invoice["line_items"], "sgst_amount")

  defp consistency_issues(invoice) do
    seller_state = state_code(invoice["seller_gstin"])
    buyer_state = state_code(invoice["buyer_gstin"])
    interstate? = seller_state && buyer_state && seller_state != buyer_state
    igst = sum(invoice["line_items"], "igst_amount")
    split = split_tax(invoice)

    cond do
      is_nil(seller_state) or is_nil(buyer_state) ->
        []

      # Both heads present is `mixed_tax_heads`, which says something stronger
      # and does not depend on the GSTINs being right. Raising both would ask a
      # reviewer to answer the same malformed invoice twice.
      igst > 0 and split > 0 ->
        []

      interstate? and igst <= 0 and split > 0 ->
        [
          issue(
            invoice,
            "tax_split_mismatch",
            "buyer state #{buyer_state} differs from seller state #{seller_state}, but tax is CGST/SGST",
            ["buyer_gstin", "line_items"],
            Issues.level_for("tax_split_mismatch")
          )
        ]

      not interstate? and split <= 0 and igst > 0 ->
        [
          issue(
            invoice,
            "tax_split_mismatch",
            "buyer state #{buyer_state} equals seller state #{seller_state}, but tax is IGST",
            ["buyer_gstin", "line_items"],
            Issues.level_for("tax_split_mismatch")
          )
        ]

      true ->
        []
    end
  end

  @doc """
  The invoice-number series as extraction read it: `from`/`to` bound the run,
  `missing` names the gaps and `duplicates` the numbers issued twice, each
  carrying the series suffix, ready to print. `nil` when no invoice number
  parses — the same months for which `derive/2` files an empty `doc_det`.

  The account block and the fold's summary line render this, and
  `sequence_gaps` is raised from the same reading, so the sentence a reviewer
  is shown and the issue that demands his decision can never name different
  gaps.
  """
  def series_account(invoices) do
    case parsed_numbers(invoices) do
      [] ->
        nil

      parsed ->
        numbers = Enum.map(parsed, & &1.number)
        suffix = parsed |> hd() |> Map.fetch!(:suffix)
        min = Enum.min(numbers)
        max = Enum.max(numbers)

        %{
          from: "#{min}#{suffix}",
          to: "#{max}#{suffix}",
          missing: Enum.map(Enum.to_list(min..max) -- numbers, &"#{&1}#{suffix}"),
          duplicates:
            (numbers -- Enum.uniq(numbers)) |> Enum.uniq() |> Enum.map(&"#{&1}#{suffix}")
        }
    end
  end

  defp correction_target(invoices, %{"source_id" => source_id}) when is_binary(source_id) do
    if Enum.any?(invoices, &(source_id(&1) == source_id)), do: source_id
  end

  defp correction_target(invoices, correction) do
    case correction["invoice"] || correction["inum"] do
      invoice_number when is_binary(invoice_number) ->
        matches = Enum.filter(invoices, &(&1["invoice_number"] == invoice_number))
        if length(matches) == 1, do: matches |> hd() |> source_id()

      _missing ->
        nil
    end
  end

  defp sequence_issues(invoices) do
    case series_account(invoices) do
      %{missing: [_ | _] = missing} ->
        [
          %{
            "invoice" => nil,
            "code" => "sequence_gaps",
            "level" => Issues.level_for("sequence_gaps"),
            "message" =>
              "missing/cancelled inferred from sequence: #{Enum.join(missing, ", ")} — confirm cancellation records",
            "fields" => ["doc_issue"]
          }
        ]

      _complete_or_unparseable ->
        []
    end
  end

  # `level` is positional and required. A default of any value reinstates the
  # defect this replaced: a newly added check silently becomes filing-gating
  # because its author forgot to classify it. Compile-time arity is the
  # enforcement; `Nila.Gst.Issues` is where the classification is decided.
  defp issue(invoice, code, message, fields, level) do
    %{
      "invoice" => invoice["invoice_number"],
      "source_id" => source_id(invoice),
      "code" => code,
      "message" => message,
      "fields" => fields,
      "level" => level
    }
  end

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

  # The HSN summary reports the code the bill prints, at the length it prints it.
  #
  # This used to truncate to four digits, which was fitted to one client whose
  # filing software does that: breeze's bills print `998719` and their returns
  # carry `9987`. Caltech's software does not, so every caltech HSN row was
  # guaranteed to mismatch — we filed `2903` against a portal holding `29037100`.
  # Truncating is permitted below ₹5cr turnover, never more correct, and it tells
  # a reviewer less. A client whose CA insists on the shorter form is a per-client
  # filing preference, not an engine rule.
  @doc """
  The HSN summary with its contributors: the portal's `hsn_b2b` rows, each also
  carrying `"contribs"` — the invoices whose lines built the row, with what each
  one put into it. The workings screen expands a row into exactly these, and
  `derive/2` files these same rows minus the key, so the aggregate a reviewer
  opens and the JSON the portal receives are one grouping, not two that happen
  to agree. A contributor's tax runs through the same `computed_bucket_tax` as
  the row's, so an expansion cannot use arithmetic the aggregate didn't.
  """
  def hsn_summary(invoices) do
    invoices
    |> Enum.flat_map(fn invoice ->
      Enum.map(invoice["line_items"] || [], &{invoice["invoice_number"], &1})
    end)
    |> Enum.group_by(fn {_inum, line} -> {hsn_code(line["hsn_sac"]), line_rate(line)} end)
    |> Enum.map(fn {{hsn, rate}, tagged} ->
      lines = Enum.map(tagged, &elem(&1, 1))
      intra_tax = mode_tax(lines, rate, :intrastate)
      inter_tax = mode_tax(lines, rate, :interstate)

      %{
        "hsn_sc" => hsn,
        "rt" => normalize_number(rate),
        "uqc" => if(String.starts_with?(to_string(hsn), "99"), do: "NA", else: "OTH"),
        "qty" => 0,
        "txval" => round2(sum(lines, "taxable_value")),
        "camt" => intra_tax.camt,
        "samt" => intra_tax.samt,
        "iamt" => inter_tax.iamt,
        "description" => official_hsn_description(lines),
        "contribs" => hsn_contribs(tagged, rate)
      }
    end)
    |> Enum.sort_by(& &1["hsn_sc"])
    |> Enum.with_index(1)
    |> Enum.map(fn {row, index} -> Map.put(row, "num", index) end)
  end

  defp hsn_contribs(tagged, rate) do
    lines_by_inum = Enum.group_by(tagged, &elem(&1, 0), &elem(&1, 1))

    for inum <- tagged |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      lines = lines_by_inum[inum]
      intra = mode_tax(lines, rate, :intrastate)
      inter = mode_tax(lines, rate, :interstate)

      %{
        "inum" => inum,
        "txval" => round2(sum(lines, "taxable_value")),
        "tax" => round2(intra.camt + intra.samt + inter.iamt)
      }
    end
  end

  defp official_hsn_description(lines) do
    lines
    |> Enum.map(& &1["hsn_description"])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.max_by(fn {_description, count} -> count end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp mode_tax(lines, rate, mode),
    do: lines |> Enum.filter(&(tax_mode(&1) == mode)) |> computed_bucket_tax(rate, mode)

  defp derive_hsn(invoices) do
    invoices |> hsn_summary() |> Enum.map(&Map.drop(&1, ["contribs", "description"]))
  end

  @doc """
  Taxable and tax by rate across the month, summed off the derived `b2b` — the
  buckets are the very `itm_det`s the portal receives, never regrouped from the
  invoices — with `"contribs"` naming each bucket's contributors, and what each
  invoice put into the bucket, for the workings screen to open.
  """
  def rate_summary(derived) do
    derived["b2b"]
    |> List.wrap()
    |> Enum.flat_map(fn party ->
      Enum.flat_map(party["inv"] || [], fn inv ->
        Enum.map(inv["itms"] || [], fn itm -> {inv["inum"], itm["itm_det"] || %{}} end)
      end)
    end)
    |> Enum.group_by(fn {_inum, det} -> det["rt"] end)
    |> Enum.map(fn {rate, tagged} ->
      dets = Enum.map(tagged, &elem(&1, 1))

      %{
        "rate" => rate,
        "taxable" => round2(det_taxable(dets)),
        "tax" => round2(det_tax(dets)),
        "contribs" => rate_contribs(tagged)
      }
    end)
    |> Enum.sort_by(& &1["rate"])
  end

  defp rate_contribs(tagged) do
    dets_by_inum = Enum.group_by(tagged, &elem(&1, 0), &elem(&1, 1))

    for inum <- tagged |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      dets = dets_by_inum[inum]

      %{
        "inum" => inum,
        "txval" => round2(det_taxable(dets)),
        "tax" => round2(det_tax(dets))
      }
    end
  end

  defp det_taxable(dets), do: dets |> Enum.map(&num(&1["txval"])) |> Enum.sum()

  defp det_tax(dets),
    do: dets |> Enum.map(&(num(&1["camt"]) + num(&1["samt"]) + num(&1["iamt"]))) |> Enum.sum()

  defp derive_doc_issue(invoices), do: invoices |> parsed_numbers() |> build_doc_issue()

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
    case parse_field_path(field) do
      {:line, index, line_field} ->
        update_in(invoice, ["line_items", Access.at(index)], fn line ->
          Map.put(line || %{}, line_field, value)
        end)

      {:invoice, field} ->
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

  # Which government gets paid. Two sources can answer and they do not always
  # agree: the two GSTINs, and whichever head the supplier actually populated on
  # the bill. When they disagree, `Values.head_reassignment/2` names it and
  # `tax_split_mismatch` (or `mixed_tax_heads`) gates the month, so no return is
  # filed on an unreviewed guess.
  #
  # The GSTIN pair wins here, and that is a deliberate default rather than an
  # accident of ordering. It is an *inference* about place of supply and it is
  # wrong in real cases — bill-to/ship-to under s.10(1)(b), goods delivered out
  # of state — but it is the only source available for an invoice whose heads
  # were never populated, and it is the reading the portal itself applies. The
  # extracted heads are the supplier's own declaration and are used only when
  # the states cannot be read at all.
  #
  # Changing this changes what gets filed. It is not a refactor.
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

  # The portal wants `idt` as DD-MM-YYYY. Swapping separators on whatever the
  # model printed only produced that by luck — an ISO date came out ISO and was
  # filed that way. Anything datable is formatted; anything else is passed
  # through, because a date we cannot read is a question for the reviewer
  # (`unreadable_invoice_date`), not something to invent a format for.
  defp normalize_date(nil), do: nil

  defp normalize_date(%Date{} = date), do: Calendar.strftime(date, "%d-%m-%Y")

  defp normalize_date(date) do
    case Books.parse_date(to_string(date)) do
      %Date{} = parsed -> normalize_date(parsed)
      nil -> date |> to_string() |> String.trim() |> String.replace(~r/[.\/]/, "-")
    end
  end

  defp hsn_code(nil), do: nil
  defp hsn_code(hsn), do: hsn |> to_string() |> String.replace(~r/\D/, "")

  # Dates are parsed at the boundary, so every kind of dump carries the same
  # type downstream and a check written once covers all of them. An unparseable
  # date keeps its printed text rather than becoming nil — losing it would hide
  # the problem instead of showing it — and `unreadable_invoice_date` says so.
  defp normalize_invoice_date(nil), do: nil

  defp normalize_invoice_date(%Date{} = date), do: date

  defp normalize_invoice_date(value) do
    case Books.parse_date(to_string(value)) do
      %Date{} = date -> date
      nil -> value
    end
  end

  defp normalize_invoice_number(nil), do: nil

  defp normalize_invoice_number(invoice_number) do
    invoice_number
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s*\/\s*/, "/")
  end

  # The series reading, shared by `series_account/1` (what a reviewer is shown)
  # and `derive_doc_issue/1` (what gets filed as doc_det). Two copies meant the
  # printed sentence and the filed table could in principle read the series
  # differently.
  defp parsed_numbers(invoices) do
    invoices
    |> Enum.map(&parse_invoice_number(&1["invoice_number"]))
    |> Enum.reject(&is_nil/1)
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

  @doc """
  Whether this is a valid GSTIN, case-insensitively.

  Defers to `Nila.Gstin`, which every other caller already used. This module
  carried its own copy of the base-36 checksum — arithmetically identical, but
  gated on `^\\d{2}[A-Z0-9]{13}$` instead of the real layout, so a string with
  the wrong PAN shape and a coincidentally correct check digit was valid to the
  filing engine and invalid to purchase reconciliation and to the client form
  that captured the GSTIN in the first place. One rule, in the module whose
  moduledoc already claimed to be the only one.

  Case is normalized here rather than in `Nila.Gstin`: a printed GSTIN is
  whatever the scan gave us, while the form fields that call `Nila.Gstin`
  directly are storing a canonical value and should not silently accept a
  lowercase one. Purchase does the same thing in `Books.clean_gstin/1`.
  """
  def valid_gstin?(gstin) when is_binary(gstin),
    do: gstin |> String.trim() |> String.upcase() |> Nila.Gstin.valid?()

  def valid_gstin?(_), do: false

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
    value = String.replace(value, ~r/[^0-9.\-]/, "")

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

  defp flag_key(%{"source_id" => source_id, "field" => field}), do: {source_id, field}
  defp flag_key(%{"invoice" => invoice, "field" => field}), do: {invoice, field}
  defp flag_key(%{"inum" => invoice, "field" => field}), do: {invoice, field}
end
