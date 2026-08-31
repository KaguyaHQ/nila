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
  alias Nila.Gst.Extraction.LineAmounts
  alias Nila.Gst.InvoiceFacts
  alias Nila.Gst.Issues
  alias Nila.Gst.Money
  alias Nila.Gst.StateCodes
  alias Nila.Gst.Purchase.Books
  alias Nila.Gst.Sales.{Gstr1Readiness, Invoice, InvoiceValidation}

  @confidence_threshold 0.90
  @correctable_invoice_fields ~w(
    document_type document_status supply_type recipient_registration place_of_supply
    invoice_number invoice_date seller_name seller_gstin buyer_name buyer_gstin
    printed_total_taxable printed_total_tax printed_grand_total
  )
  @correctable_line_fields ~w(
    item_name description hsn_sac quantity uom printed_unit_price printed_line_amount
    printed_line_total printed_taxable_value line_amount_tax_inclusion taxable_value
    cgst_rate cgst_amount sgst_rate sgst_amount igst_rate igst_amount
  )
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
    case Invoice.parse_field_path(field) do
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
  defdelegate source_id(invoice), to: Invoice

  @doc "Reads a scalar invoice field, including `line_items[index].field` paths."
  defdelegate field_value(invoice, field_path), to: Invoice

  @doc "Coerces correction text for the numeric fields accepted by the review UI."
  defdelegate coerce_correction(field_path, text), to: Invoice

  @doc "Sums extracted taxable and tax amounts without deriving or rounding them."
  defdelegate extracted_totals(invoice), to: Invoice

  @doc "Re-resolves normalized line amounts from their preserved printed evidence."
  defdelegate resolve_line_amounts(invoice), to: Invoice

  @doc "Whether every line has a known taxable value, including a genuine zero."
  defdelegate taxable_values_complete?(invoice), to: Invoice

  def normalize_invoice(raw) when is_map(raw) do
    data = raw["data"] || raw["extract_result"] || raw["result"] || raw
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
        normalize_place_of_supply(
          data["printed_place_of_supply"] || data["place_of_supply"] ||
            buyer["place_of_supply"]
        ),
      "document_status" => normalize_document_status(data["document_status"]),
      "supply_type" => normalize_supply_type(data["supply_type"], document),
      "line_items" => line_items,
      "printed_total_taxable" =>
        money(value(data, ["printed_total_taxable", "total_net_amount"])),
      "printed_tax_totals" => data["printed_tax_totals"],
      "tax_total_issues" => data["tax_total_issues"],
      "printed_total_tax" => money(value(data, ["printed_total_tax", "total_tax_amount"])),
      "printed_grand_total" => money(value(data, ["printed_grand_total", "total_gross_amount"])),
      "confidence" => non_empty_map(raw["confidence"]) || build_confidence(raw),
      "verification" => non_empty_map(raw["verification"]),
      "document" => document
    }
    |> InvoiceFacts.from_sales_map!()
    |> InvoiceFacts.to_sales_map()
  end

  defp normalize_party(party) when is_map(party) do
    party
    |> Map.take(["name", "gstin", "address", "state_code"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp normalize_party(_party), do: nil

  @doc "The canonical source-document classification used by filing and accounting."
  def document_type(invoice), do: invoice["document_type"] || "invoice"

  @doc "Recipient registration with backward-compatible inference for stored registered invoices."
  def recipient_registration(invoice) do
    invoice["recipient_registration"] ||
      if(is_nil(blank_to_nil(invoice["buyer_gstin"])), do: "unknown", else: "registered")
  end

  @doc "The source document's number, retained in the legacy invoice-number storage key."
  def document_number(invoice), do: invoice["invoice_number"]

  @doc "The source document's date, retained in the legacy invoice-date storage key."
  def document_date(invoice), do: invoice["invoice_date"]

  @doc "The direction this source document contributes to outward liability."
  def document_effect(invoice) do
    if document_type(invoice) == "credit_note", do: -1, else: 1
  end

  @doc "The supported GSTR-1 table for one normalized source document, or nil when held out."
  def filing_table(invoice) do
    seller_state = state_code(invoice["seller_gstin"])
    pos = effective_place_of_supply(invoice)

    cond do
      document_status(invoice) != "active" ->
        nil

      supply_type(invoice) != "taxable" ->
        nil

      is_nil(seller_state) or is_nil(pos) ->
        nil

      recipient_registration(invoice) == "registered" and document_type(invoice) == "invoice" ->
        "b2b"

      recipient_registration(invoice) == "registered" and
          document_type(invoice) in ~w(credit_note debit_note) ->
        "cdnr"

      recipient_registration(invoice) == "unregistered" and document_type(invoice) != "invoice" ->
        nil

      recipient_registration(invoice) == "unregistered" and seller_state == pos ->
        "b2cs"

      recipient_registration(invoice) == "unregistered" ->
        b2c_interstate_table(invoice)

      true ->
        nil
    end
  end

  @doc "The portal item details for one supported source document."
  def filing_details(invoice) do
    seller_state = state_code(invoice["seller_gstin"])
    pos = effective_place_of_supply(invoice)

    if not is_nil(filing_table(invoice)) and taxable_values_complete?(invoice) do
      invoice
      |> derive_items(seller_state, pos)
      |> Enum.map(&(&1["itm_det"] || %{}))
    else
      []
    end
  end

  def validation_issues(invoices) do
    month_validation_issues(invoices) ++ invoice_validation_issues(invoices)
  end

  @doc "Issues intrinsic to the supplied invoices, independent of month completeness."
  defdelegate invoice_validation_issues(invoices), to: InvoiceValidation, as: :issues

  @doc "Controls that are meaningful only for a complete sales month."
  def month_validation_issues(invoices), do: sequence_issues(invoices)

  @doc """
  Issues that must be answered before a GSTR-1 can be signed, not merely read.

  `derive/2` builds registered `b2b` and `cdnr`, `hsn` and `doc_issue`. A
  document that belongs in another table would still be derived as the closest
  supported outward supply: an export or SEZ supply would be filed as ordinary
  taxable B2B; a reverse-charge supply would be filed `rchrg: "N"` and the tax
  charged to the wrong party.

  None of these can be caught downstream: every one is arithmetically perfect.
  So the return refuses to be signed while one is present, and the missing table
  gets built when a real document asks for it rather than from imagination.
  """
  def blocking_issues(invoices) do
    gstr1_capability_issues(invoices) ++ duplicate_number_issues(invoices)
  end

  @doc "Document treatments the current GSTR-1 projection cannot represent."
  defdelegate gstr1_capability_issues(invoices), to: Gstr1Readiness, as: :capability_issues

  @doc "One blocking issue per duplicate active invoice-number group."
  defdelegate duplicate_number_issues(invoices), to: InvoiceValidation

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
    complete = Enum.filter(invoices, &taxable_values_complete?/1)
    b2b_invoices = Enum.filter(complete, &(filing_table(&1) == "b2b"))
    b2cs_invoices = Enum.filter(complete, &(filing_table(&1) == "b2cs"))
    b2cl_invoices = Enum.filter(complete, &(filing_table(&1) == "b2cl"))
    notes = Enum.filter(complete, &(filing_table(&1) == "cdnr"))

    %{
      "gstin" => seller_gstin,
      "fp" => filed["fp"],
      "filing_typ" => filed["filing_typ"] || "M",
      "gt" => filed["gt"] || 0.0,
      "cur_gt" => filed["cur_gt"] || 0.0,
      "b2b" => derive_b2b(b2b_invoices, seller_state),
      "b2cl" => derive_b2cl(b2cl_invoices, seller_state),
      "b2cs" => derive_b2cs(b2cs_invoices, seller_state),
      "cdnr" => derive_cdnr(notes, seller_state),
      "hsn" => %{
        "hsn_b2b" => derive_hsn(b2b_invoices ++ notes),
        "hsn_b2c" => derive_b2c_hsn(b2cs_invoices ++ b2cl_invoices)
      },
      "doc_issue" => derive_doc_issue(invoices),
      "fil_dt" => filed["fil_dt"]
    }
  end

  defp derive_b2b(invoices, seller_state) do
    invoices
    |> Enum.group_by(& &1["buyer_gstin"])
    |> Enum.map(fn {ctin, buyer_invoices} ->
      %{
        "ctin" => ctin,
        "inv" =>
          Enum.map(
            Enum.sort_by(buyer_invoices, &invoice_sort_key(document_number(&1))),
            &derive_invoice(&1, seller_state)
          )
      }
    end)
    |> Enum.sort_by(& &1["ctin"])
  end

  defp derive_b2cl(invoices, seller_state) do
    invoices
    |> Enum.group_by(&effective_place_of_supply/1)
    |> Enum.map(fn {pos, pos_invoices} ->
      %{
        "pos" => pos,
        "inv" =>
          Enum.map(
            Enum.sort_by(pos_invoices, &invoice_sort_key(document_number(&1))),
            &derive_b2cl_invoice(&1, seller_state)
          )
      }
    end)
    |> Enum.sort_by(& &1["pos"])
  end

  defp derive_b2cs(invoices, seller_state) do
    invoices
    |> Enum.flat_map(fn invoice ->
      pos = effective_place_of_supply(invoice)
      supply_type = if(pos == seller_state, do: "INTRA", else: "INTER")

      invoice
      |> derive_items(seller_state, pos)
      |> Enum.map(fn item ->
        detail = item["itm_det"] || %{}
        {{pos, "OE", detail["rt"], supply_type}, detail}
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {{pos, type, rate, supply_type}, details} ->
      %{
        "pos" => pos,
        "typ" => type,
        "txval" => round2(det_taxable(details)),
        "iamt" => round2(sum_maps(details, "iamt")),
        "camt" => round2(sum_maps(details, "camt")),
        "samt" => round2(sum_maps(details, "samt")),
        "csamt" => round2(sum_maps(details, "csamt")),
        "rt" => normalize_number(rate),
        "sply_ty" => supply_type
      }
    end)
    |> Enum.sort_by(&{&1["pos"], &1["rt"]})
  end

  defp derive_cdnr(notes, seller_state) do
    notes
    |> Enum.group_by(& &1["buyer_gstin"])
    |> Enum.map(fn {ctin, buyer_notes} ->
      %{
        "ctin" => ctin,
        "nt" =>
          Enum.map(
            Enum.sort_by(buyer_notes, &invoice_sort_key(document_number(&1))),
            &derive_note(&1, seller_state)
          )
      }
    end)
    |> Enum.sort_by(& &1["ctin"])
  end

  defp normalize_line(line) do
    cgst = line["cgst"] || %{}
    sgst = line["sgst"] || %{}
    igst = line["igst"] || %{}
    cgst_rate = money(line["cgst_rate"] || cgst["rate"])
    sgst_rate = money(line["sgst_rate"] || sgst["rate"])
    igst_rate = money(line["igst_rate"] || igst["rate"])

    amount_line =
      line
      |> Map.put("cgst_rate", cgst_rate)
      |> Map.put("sgst_rate", sgst_rate)
      |> Map.put("igst_rate", igst_rate)
      |> Map.put_new("taxable_value", value(line, ["taxable", "net_amount", "txval"]))
      |> Map.put_new("unit_price", line["rate"])

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
      "cgst_amount" => money(line["cgst_amount"] || cgst["amount"] || line["camt"]),
      "sgst_rate" => sgst_rate,
      "sgst_amount" => money(line["sgst_amount"] || sgst["amount"] || line["samt"]),
      "igst_rate" => igst_rate,
      "igst_amount" => money(line["igst_amount"] || igst["amount"] || line["iamt"])
    }
  end

  defp resolve_line_amount(line), do: Invoice.resolve_line_amount(line)

  @doc """
  Arithmetic check outcomes for one invoice — passed and failed alike, each with
  the operands a screen can print (`15,200 × 18% = 2,736 ✓`).

  `InvoiceValidation` is the sole judge of these checks: `validation_issues/1`
  raises the failing subset and presentation layers consume those outcomes
  without applying another threshold, so a ✓ can never sit beside an open
  issue for the same check. A check only exists where the bill makes a
  claim — a furniture row with no values, or an absent printed total, yields no
  outcome rather than a vacuous pass.

  Failures outnumber issues, because an issue is a resolution target: the
  failing lines of one check collapse into one issue, and a bill total that is
  out by exactly what its components are out by is folded into theirs. Every
  failure still prints its own ✗ with its own operands; what it no longer gets
  is its own card and its own button.
  """
  def invoice_checks(invoice) do
    InvoiceValidation.checks(invoice)
  end

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
    accounts =
      invoices
      |> Enum.filter(&(document_type(&1) == "invoice"))
      |> series_accounts()

    case Enum.max_by(accounts, & &1.count, fn -> nil end) do
      nil ->
        nil

      primary ->
        primary
        |> Map.put(:missing, Enum.flat_map(accounts, & &1.missing))
        |> Map.put(:duplicates, Enum.flat_map(accounts, & &1.duplicates))
        |> Map.delete(:count)
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
    missing =
      invoices
      |> Enum.filter(&(document_type(&1) == "invoice"))
      |> series_accounts()
      |> Enum.flat_map(& &1.missing)

    if missing == [] do
      []
    else
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
    end
  end

  defp derive_invoice(invoice, seller_state) do
    pos = effective_place_of_supply(invoice)

    %{
      "inum" => document_number(invoice),
      "idt" => normalize_date(document_date(invoice)),
      "val" => document_value(invoice),
      "pos" => pos,
      "rchrg" => "N",
      "inv_typ" => "R",
      "itms" => derive_items(invoice, seller_state, pos)
    }
  end

  defp derive_b2cl_invoice(invoice, seller_state) do
    pos = effective_place_of_supply(invoice)

    %{
      "inum" => document_number(invoice),
      "idt" => normalize_date(document_date(invoice)),
      "val" => document_value(invoice),
      "itms" =>
        invoice
        |> derive_items(seller_state, pos)
        |> Enum.map(fn item ->
          update_in(item, ["itm_det"], &drop_zero_fields(&1, ~w(camt samt)))
        end)
    }
  end

  defp derive_note(note, seller_state) do
    pos = effective_place_of_supply(note)

    %{
      "nt_num" => document_number(note),
      "nt_dt" => normalize_date(document_date(note)),
      "ntty" => note_type(document_type(note)),
      "val" => document_value(note),
      "pos" => pos,
      "rchrg" => "N",
      "inv_typ" => "R",
      "itms" => derive_items(note, seller_state, pos)
    }
  end

  defp note_type("credit_note"), do: "C"
  defp note_type("debit_note"), do: "D"

  defp derive_items(document, seller_state, place_of_supply) do
    document["line_items"]
    |> Enum.group_by(&line_rate/1)
    |> Enum.sort_by(fn {rate, _lines} -> rate end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{rate, lines}, index} ->
      tax =
        computed_bucket_tax(lines, rate, invoice_tax_mode(lines, seller_state, place_of_supply))

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
  end

  defp document_value(document),
    do: round2(invoice_taxable(document) + invoice_tax(document))

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
    |> Enum.filter(&taxable_values_complete?/1)
    |> Enum.flat_map(&document_hsn_contributions/1)
    |> Enum.group_by(&{&1["hsn_sc"], &1["rt"]})
    |> Enum.map(fn {{hsn, rate}, contribs} ->
      %{
        "hsn_sc" => hsn,
        "rt" => normalize_number(rate),
        "uqc" => if(String.starts_with?(to_string(hsn), "99"), do: "NA", else: "OTH"),
        "qty" => 0,
        "txval" => round2(sum_maps(contribs, "txval")),
        "camt" => round2(sum_maps(contribs, "camt")),
        "samt" => round2(sum_maps(contribs, "samt")),
        "iamt" => round2(sum_maps(contribs, "iamt")),
        "description" => official_hsn_description(Enum.flat_map(contribs, & &1["lines"])),
        "contribs" => Enum.map(contribs, &Map.take(&1, ~w(inum txval tax)))
      }
    end)
    |> Enum.sort_by(& &1["hsn_sc"])
    |> Enum.with_index(1)
    |> Enum.map(fn {row, index} -> Map.put(row, "num", index) end)
  end

  defp document_hsn_contributions(document) do
    effect = document_effect(document)

    document["line_items"]
    |> List.wrap()
    |> Enum.group_by(&{hsn_code(&1["hsn_sac"]), line_rate(&1)})
    |> Enum.map(fn {{hsn, rate}, lines} ->
      intra = mode_tax(lines, rate, :intrastate)
      inter = mode_tax(lines, rate, :interstate)
      txval = effect * round2(sum(lines, "taxable_value"))
      camt = effect * intra.camt
      samt = effect * intra.samt
      iamt = effect * inter.iamt

      %{
        "inum" => document_number(document),
        "hsn_sc" => hsn,
        "rt" => rate,
        "txval" => txval,
        "camt" => camt,
        "samt" => samt,
        "iamt" => iamt,
        "tax" => round2(camt + samt + iamt),
        "lines" => lines
      }
    end)
  end

  defp sum_maps(maps, field), do: maps |> Enum.map(&num(&1[field])) |> Enum.sum()

  defp drop_zero_fields(map, fields) do
    Enum.reduce(fields, map, fn field, acc ->
      if num(acc[field]) == 0, do: Map.delete(acc, field), else: acc
    end)
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

  defp derive_b2c_hsn(invoices) do
    first_occurrence =
      invoices
      |> Enum.flat_map(&List.wrap(&1["line_items"]))
      |> Enum.map(
        &{hsn_code(&1["hsn_sac"]), normalize_number(line_rate(&1)), uqc(&1["uom"], &1["hsn_sac"])}
      )
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new()

    invoices
    |> Enum.flat_map(&b2c_hsn_contributions/1)
    |> Enum.group_by(&{&1["hsn_sc"], &1["rt"], &1["uqc"]})
    |> Enum.map(fn {{hsn, rate, uqc}, contribs} ->
      lines = Enum.flat_map(contribs, & &1["lines"])
      description = most_common(lines, "item_name") || most_common(lines, "description")

      %{
        "hsn_sc" => hsn,
        "txval" => round2(sum_maps(contribs, "txval")),
        "iamt" => round2(sum_maps(contribs, "iamt")),
        "camt" => round2(sum_maps(contribs, "camt")),
        "samt" => round2(sum_maps(contribs, "samt")),
        "csamt" => 0.0,
        "desc" => description,
        "user_desc" => description,
        "uqc" => uqc,
        "qty" => round2(sum_maps(contribs, "qty")),
        "rt" => normalize_number(rate)
      }
    end)
    |> Enum.sort_by(fn row ->
      {Map.fetch!(first_occurrence, {row["hsn_sc"], row["rt"], row["uqc"]}), row["hsn_sc"]}
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, index} -> Map.put(row, "num", index) end)
  end

  defp b2c_hsn_contributions(invoice) do
    seller_state = state_code(invoice["seller_gstin"])
    pos = effective_place_of_supply(invoice)

    invoice["line_items"]
    |> List.wrap()
    |> Enum.group_by(fn line ->
      {hsn_code(line["hsn_sac"]), line_rate(line), uqc(line["uom"], line["hsn_sac"])}
    end)
    |> Enum.map(fn {{hsn, rate, uqc}, lines} ->
      tax = computed_bucket_tax(lines, rate, invoice_tax_mode(lines, seller_state, pos))

      %{
        "hsn_sc" => hsn,
        "rt" => rate,
        "uqc" => uqc,
        "qty" => sum(lines, "quantity"),
        "txval" => tax.txval,
        "camt" => tax.camt,
        "samt" => tax.samt,
        "iamt" => tax.iamt,
        "lines" => lines
      }
    end)
  end

  defp most_common(rows, field) do
    rows
    |> Enum.map(& &1[field])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.max_by(fn {value, count} -> {count, value} end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp uqc(uom, hsn) do
    if is_binary(hsn) and String.starts_with?(hsn, "99"),
      do: "NA",
      else: normalize_uqc(uom)
  end

  defp normalize_uqc(uom) do
    normalized = uom |> to_string() |> String.trim() |> String.downcase()

    cond do
      normalized in ~w(no nos number numbers pc pcs piece pieces) -> "NOS"
      normalized in ~w(kg kgs kilogram kilograms) -> "KGS"
      normalized in ~w(l ltr ltrs litre litres liter liters) -> "LTR"
      normalized in ~w(m mtr mtrs metre metres meter meters) -> "MTR"
      String.length(normalized) == 3 -> String.upcase(normalized)
      true -> "OTH"
    end
  end

  @doc """
  Taxable and tax by rate across the month, summed off the derived `b2b` — the
  buckets are the very `itm_det`s the portal receives, never regrouped from the
  invoices — with `"contribs"` naming each bucket's contributors, and what each
  invoice put into the bucket, for the workings screen to open.
  """
  def rate_summary(derived) do
    derived
    |> signed_details()
    |> Enum.map(fn entry -> {entry.number, entry.detail} end)
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

  @doc "Every filed rate bucket with its outward-liability sign already applied."
  def signed_details(derived) do
    invoice_details =
      for party <- derived["b2b"] || [],
          invoice <- party["inv"] || [],
          item <- invoice["itms"] || [],
          do: %{number: invoice["inum"], type: "invoice", detail: item["itm_det"] || %{}}

    b2cl_details =
      for pos_block <- derived["b2cl"] || [],
          invoice <- pos_block["inv"] || [],
          item <- invoice["itms"] || [],
          do: %{number: invoice["inum"], type: "invoice", detail: item["itm_det"] || %{}}

    b2cs_details =
      for row <- derived["b2cs"] || [] do
        %{
          number: "B2CS #{row["pos"]} #{row["rt"]}",
          type: "invoice",
          detail: %{
            "rt" => row["rt"],
            "txval" => row["txval"],
            "camt" => row["camt"],
            "samt" => row["samt"],
            "iamt" => row["iamt"],
            "csamt" => row["csamt"]
          }
        }
      end

    credit_details =
      for party <- derived["cdnr"] || [],
          note <- party["nt"] || [],
          item <- note["itms"] || [],
          do: %{
            number: note["nt_num"],
            type: note_document_type(note["ntty"]),
            detail: scale_detail(item["itm_det"] || %{}, note_effect(note["ntty"]))
          }

    invoice_details ++ b2cl_details ++ b2cs_details ++ credit_details
  end

  defp note_document_type("C"), do: "credit_note"
  defp note_document_type("D"), do: "debit_note"

  defp note_effect("C"), do: -1
  defp note_effect("D"), do: 1

  defp scale_detail(detail, effect) do
    Map.new(detail, fn
      {field, value} when field in ~w(txval camt samt iamt csamt) and is_number(value) ->
        {field, value * effect}

      entry ->
        entry
    end)
  end

  defp derive_doc_issue(invoices) do
    groups =
      [
        {1, Enum.filter(invoices, &(document_type(&1) == "invoice"))},
        {4, Enum.filter(invoices, &(document_type(&1) == "debit_note"))},
        {5, Enum.filter(invoices, &(document_type(&1) == "credit_note"))}
      ]
      |> Enum.flat_map(fn {doc_num, documents} ->
        case parsed_series(documents) do
          [] -> []
          series -> [%{"doc_num" => doc_num, "docs" => build_doc_issue_rows(series)}]
        end
      end)

    %{"doc_det" => groups}
  end

  defp build_doc_issue_rows(series) do
    series
    |> Enum.with_index(1)
    |> Enum.map(fn {parsed, index} ->
      numbers = Enum.map(parsed, & &1.number)
      min = Enum.min(numbers)
      max = Enum.max(numbers)
      first = hd(parsed)
      totnum = max - min + 1
      net_issue = length(Enum.uniq(numbers))

      %{
        "num" => index,
        "from" => format_series_number(min, first),
        "to" => format_series_number(max, first),
        "totnum" => totnum,
        "cancel" => totnum - net_issue,
        "net_issue" => net_issue
      }
    end)
  end

  defp put_field(invoice, field, value) do
    case Invoice.parse_field_path(field) do
      {:line, index, line_field} ->
        invoice
        |> update_in(["line_items", Access.at(index)], fn line ->
          line = line || %{}

          line =
            if line_field == "line_amount_tax_inclusion" do
              line
              |> Map.put_new(
                "line_amount_tax_inclusion_candidate",
                line["line_amount_tax_inclusion"] || "unknown"
              )
              |> Map.put("line_amount_tax_inclusion_basis", "corrected")
            else
              line
            end

          line
          |> Map.put(line_field, value)
          |> update_corrected_taxable(line_field)
        end)
        |> clear_verification_failure(field)

      {:invoice, "buyer_gstin"} ->
        corrected =
          case blank_to_nil(value) do
            nil ->
              Map.put(invoice, "buyer_gstin", nil)

            gstin ->
              invoice
              |> Map.put("buyer_gstin", gstin)
              |> Map.put("recipient_registration", "registered")
          end

        clear_verification_failure(corrected, "buyer_gstin")

      {:invoice, "place_of_supply"} ->
        Map.put(invoice, "place_of_supply", normalize_place_of_supply(value))

      {:invoice, "recipient_registration"} ->
        Map.put(invoice, "recipient_registration", normalize_recipient_registration(value, nil))

      {:invoice, "document_status"} ->
        Map.put(invoice, "document_status", normalize_document_status(value))

      {:invoice, "supply_type"} ->
        Map.put(invoice, "supply_type", normalize_supply_type(value, invoice["document"] || %{}))

      {:invoice, field} ->
        invoice
        |> Map.put(field, value)
        |> clear_verification_failure(field)
    end
  end

  defp clear_verification_failure(%{"verification" => verification} = invoice, field)
       when is_map(verification) do
    update_in(invoice, ["verification", "failed_checks"], fn checks ->
      checks
      |> List.wrap()
      |> Enum.reject(&(Invoice.verification_field(&1) == field))
    end)
  end

  defp clear_verification_failure(invoice, _field), do: invoice

  defp update_corrected_taxable(line, "taxable_value"),
    do: Map.put(line, "taxable_value_basis", "corrected")

  defp update_corrected_taxable(line, field)
       when field in ~w(printed_line_amount printed_line_total printed_taxable_value line_amount_tax_inclusion cgst_rate cgst_amount sgst_rate sgst_amount igst_rate igst_amount) do
    resolve_line_amount(line)
  end

  defp update_corrected_taxable(line, _field), do: line

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

  # The supplier's printed heads are the source fact Nila is transcribing. A
  # place-of-supply default may complete a voucher, but it is not strong enough
  # to silently rewrite IGST into CGST/SGST (or the reverse). Only when the
  # source carries no head at all do the party states provide a completion
  # fallback; any disagreement is held by invoice validation for a reviewer.
  defp invoice_tax_mode(lines, seller_state, place_of_supply) do
    source_tax_mode(lines) || inferred_tax_mode(seller_state, place_of_supply)
  end

  defp source_tax_mode(lines) do
    igst? = Enum.any?(lines, &(num(&1["igst_amount"]) > 0 or num(&1["igst_rate"]) > 0))

    split? =
      Enum.any?(lines, fn line ->
        num(line["cgst_amount"]) > 0 or num(line["cgst_rate"]) > 0 or
          num(line["sgst_amount"]) > 0 or num(line["sgst_rate"]) > 0
      end)

    case {igst?, split?} do
      {true, false} -> :interstate
      {false, true} -> :intrastate
      _missing_or_mixed -> nil
    end
  end

  defp inferred_tax_mode(seller_state, place_of_supply) do
    if seller_state && place_of_supply && seller_state != place_of_supply,
      do: :interstate,
      else: :intrastate
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

  defp normalize_recipient_registration(_status, gstin)
       when is_binary(gstin) and gstin != "",
       do: "registered"

  defp normalize_recipient_registration(status, _gstin)
       when status in ~w(registered unregistered unknown),
       do: status

  defp normalize_recipient_registration(_status, _gstin), do: "unknown"

  defp normalize_place_of_supply(nil), do: nil

  defp normalize_place_of_supply(value) do
    value = value |> to_string() |> String.trim()

    StateCodes.normalize_code(value) ||
      Enum.find_value(StateCodes.all(), fn name ->
        if String.downcase(name) == String.downcase(value), do: StateCodes.code_for(name)
      end) || blank_to_nil(value)
  end

  defp document_status(invoice), do: invoice["document_status"] || "active"

  defp supply_type(invoice) do
    invoice["supply_type"] ||
      if(get_in(invoice, ["document", "export"]), do: "export", else: "taxable")
  end

  defp normalize_document_status(status) when status in ~w(active cancelled amendment unknown),
    do: status

  defp normalize_document_status(nil), do: "active"
  defp normalize_document_status(_status), do: "unknown"

  defp normalize_supply_type(status, _document)
       when status in ~w(taxable nil_rated exempt non_gst export sez unknown),
       do: status

  defp normalize_supply_type(nil, %{"export" => true}), do: "export"
  defp normalize_supply_type(nil, _document), do: "taxable"
  defp normalize_supply_type(_status, _document), do: "unknown"

  defp effective_place_of_supply(invoice) do
    case invoice["place_of_supply"] do
      pos when is_binary(pos) -> if(StateCodes.name_for(pos), do: pos)
      _missing -> state_code(invoice["buyer_gstin"])
    end
  end

  defp b2c_interstate_table(invoice) do
    case parsed_document_date(document_date(invoice)) do
      %Date{} = date ->
        threshold = if Date.before?(date, ~D[2024-08-01]), do: 250_000, else: 100_000
        if document_value(invoice) > threshold, do: "b2cl", else: "b2cs"

      nil ->
        nil
    end
  end

  defp parsed_document_date(%Date{} = date), do: date
  defp parsed_document_date(value) when is_binary(value), do: Books.parse_date(value)
  defp parsed_document_date(_value), do: nil

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
    |> normalize_invoice_number()
  end

  defp strip_document_label(number, "credit_note") do
    String.replace(number, ~r/^\s*(?:tax\s+)?credit\s+note\s*(?:no\.?|number)?\s*[:#-]?\s*/i, "")
  end

  defp strip_document_label(number, "debit_note") do
    String.replace(number, ~r/^\s*(?:tax\s+)?debit\s+note\s*(?:no\.?|number)?\s*[:#-]?\s*/i, "")
  end

  defp strip_document_label(number, _document_type), do: number

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

  defp parsed_series(documents) do
    documents
    |> parsed_numbers()
    |> Enum.group_by(&{&1.prefix, &1.suffix})
    |> Enum.sort_by(fn {key, _parsed} -> key end)
    |> Enum.map(&elem(&1, 1))
  end

  defp series_accounts(documents) do
    Enum.map(parsed_series(documents), fn parsed ->
      numbers = Enum.map(parsed, & &1.number)
      first = hd(parsed)
      min = Enum.min(numbers)
      max = Enum.max(numbers)

      %{
        from: format_series_number(min, first),
        to: format_series_number(max, first),
        missing: Enum.map(Enum.to_list(min..max) -- numbers, &format_series_number(&1, first)),
        duplicates:
          (numbers -- Enum.uniq(numbers))
          |> Enum.uniq()
          |> Enum.map(&format_series_number(&1, first)),
        count: length(parsed)
      }
    end)
  end

  defp parse_invoice_number(nil), do: nil

  defp parse_invoice_number(invoice_number) do
    normalized = normalize_invoice_number(invoice_number)

    case Regex.run(~r/^(\d+)(.*)$/, normalized) do
      [_, number, suffix] ->
        parsed_invoice_number("", number, suffix)

      _prefixed ->
        case Regex.run(~r/^(.*\D)(\d+)(\D*)$/, normalized) do
          [_, prefix, number, suffix] -> parsed_invoice_number(prefix, number, suffix)
          _unparseable -> nil
        end
    end
  end

  defp parsed_invoice_number(prefix, number, suffix) do
    %{
      prefix: prefix,
      number: String.to_integer(number),
      width: String.length(number),
      suffix: suffix
    }
  end

  defp format_series_number(number, parsed) do
    parsed.prefix <> String.pad_leading(to_string(number), parsed.width, "0") <> parsed.suffix
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
    do: Nila.Gstin.valid_extracted?(gstin)

  def valid_gstin?(_), do: false

  defp state_code(gstin), do: StateCodes.from_gstin(gstin)
  defp money(value), do: Money.rupee_number(value)

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

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

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
