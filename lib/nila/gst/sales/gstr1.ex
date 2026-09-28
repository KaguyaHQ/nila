defmodule Nila.Gst.Sales.Gstr1 do
  @moduledoc """
  Derives GSTR-1 tables and source contributions from normalized sales invoices.

  Table treatment, portal items, tax rounding, and HSN calculations stay together
  so the return and its workings use the same arithmetic. `project/2` returns
  both the portal map and the included contribution of each source; `derive/2`
  returns just the portal map. Rate summaries read that derived return.

  Invoice owns document facts, Review.CorrectionPolicy owns flagged corrections,
  Documents owns numbering controls, and Readiness owns output requirements.
  This module performs no database, file, or network operations.
  """

  alias Nila.Gst.Money
  alias Nila.Gst.StateCodes
  alias Nila.Gst.Dates
  alias Nila.Gst.Sales.Invoice
  alias Nila.Gst.Sales.TaxDetermination
  alias Nila.Gst.Sales.Gstr1.Documents
  alias Nila.Gst.Sales.Invoice.Validation, as: InvoiceValidation

  @doc "The supported GSTR-1 table for one normalized source document, or nil when held out."
  def filing_table(invoice) do
    seller_state = state_code(invoice["seller_gstin"])
    pos = effective_place_of_supply(invoice)

    cond do
      Invoice.document_status(invoice) != "active" ->
        nil

      Invoice.special_supply_conflict?(invoice) ->
        nil

      (Invoice.zero_rated?(invoice) or Invoice.reverse_charge?(invoice)) and
          Invoice.document_type(invoice) != "invoice" ->
        nil

      Invoice.zero_rated?(invoice) and
          invoice["tax_payment"] not in ~w(with_payment without_payment) ->
        nil

      Invoice.supply_type(invoice) == "export" ->
        if seller_state && is_nil(blank_to_nil(invoice["buyer_gstin"])), do: "exp", else: nil

      Invoice.supply_type(invoice) == "sez" ->
        if seller_state && pos && Invoice.recipient_registration(invoice) == "registered",
          do: "b2b",
          else: nil

      Invoice.reverse_charge?(invoice) and Invoice.recipient_registration(invoice) != "registered" ->
        nil

      Invoice.supply_type(invoice) in ~w(nil_rated exempt non_gst) ->
        if seller_state && pos &&
             Invoice.recipient_registration(invoice) in ~w(registered unregistered) &&
             invoice_tax(invoice) == 0 &&
             num(Nila.Gst.TaxComponents.printed_tax_total(invoice)) == 0 &&
             Enum.all?(invoice["line_items"] || [], &(line_rate(&1) == 0)), do: "nil", else: nil

      Invoice.supply_type(invoice) != "taxable" ->
        nil

      is_nil(seller_state) or is_nil(pos) ->
        nil

      Invoice.recipient_registration(invoice) == "registered" and
          Invoice.document_type(invoice) == "invoice" ->
        "b2b"

      Invoice.recipient_registration(invoice) == "registered" and
          Invoice.document_type(invoice) in ~w(credit_note debit_note) ->
        "cdnr"

      Invoice.recipient_registration(invoice) == "unregistered" and
          Invoice.document_type(invoice) != "invoice" ->
        cond do
          seller_state == pos -> "b2cs"
          invoice["original_sale_category"] == "b2cs" -> "b2cs"
          invoice["original_sale_category"] == "b2cl" -> "cdnur"
          true -> nil
        end

      Invoice.recipient_registration(invoice) == "unregistered" and seller_state == pos ->
        "b2cs"

      Invoice.recipient_registration(invoice) == "unregistered" ->
        b2c_interstate_table(invoice)

      true ->
        nil
    end
  end

  @doc "The portal item details for one supported source document."
  def filing_details(invoice) do
    seller_state = state_code(invoice["seller_gstin"])
    pos = effective_place_of_supply(invoice)

    if not is_nil(filing_table(invoice)) and Invoice.taxable_values_complete?(invoice) and
         not TaxDetermination.unresolved?(invoice) do
      invoice
      |> derive_items(seller_state, pos)
      |> Enum.map(&(&1["itm_det"] || %{}))
    else
      []
    end
  end

  def validation_issues(invoices) do
    Documents.issues(invoices) ++ InvoiceValidation.issues(invoices)
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

  def derive(invoices, filed), do: project(invoices, filed).derived

  @doc "Builds the portal return and its included contributions keyed by source ID."
  def project(invoices, filed) do
    seller_gstin = filed["gstin"] || first_present(invoices, "seller_gstin")
    seller_state = state_code(seller_gstin)

    classified =
      for invoice <- invoices,
          Invoice.taxable_values_complete?(invoice),
          not TaxDetermination.unresolved?(invoice),
          table = filing_table(invoice),
          not is_nil(table),
          do: {invoice, table}

    by_table = Enum.group_by(classified, &elem(&1, 1), &elem(&1, 0))

    entries =
      Map.new(classified, fn {invoice, table} ->
        {invoice, contribution_entry(invoice, table, seller_state)}
      end)

    b2b_invoices = Map.get(by_table, "b2b", [])
    b2cs_invoices = Map.get(by_table, "b2cs", [])
    b2cl_invoices = Map.get(by_table, "b2cl", [])
    notes = Map.get(by_table, "cdnr", [])
    unregistered_notes = Map.get(by_table, "cdnur", [])
    nil_supplies = Map.get(by_table, "nil", [])
    exports = Map.get(by_table, "exp", [])

    {nil_b2b, nil_b2c} =
      Enum.split_with(nil_supplies, &(Invoice.recipient_registration(&1) == "registered"))

    {nil_return, entries} = derive_nil_supplies(nil_supplies, entries)

    derived = %{
      "gstin" => seller_gstin,
      "fp" => filed["fp"],
      "filing_typ" => filed["filing_typ"] || "M",
      "gt" => filed["gt"] || 0.0,
      "cur_gt" => filed["cur_gt"] || 0.0,
      "b2b" => derive_b2b(b2b_invoices, entries),
      "exp" => derive_exports(exports, entries),
      "b2cl" => derive_b2cl(b2cl_invoices, entries),
      "b2cs" => derive_b2cs(b2cs_invoices, entries),
      "cdnr" => derive_cdnr(notes, entries),
      "cdnur" =>
        Enum.map(unregistered_notes, fn note ->
          Map.fetch!(entries, note)
        end),
      "hsn" => %{
        "hsn_b2b" => derive_hsn(b2b_invoices ++ notes ++ nil_b2b),
        "hsn_b2c" =>
          derive_b2c_hsn(
            b2cs_invoices ++ b2cl_invoices ++ unregistered_notes ++ nil_b2c ++ exports
          )
      },
      "nil" => nil_return,
      "doc_issue" => Documents.derive(invoices),
      "fil_dt" => filed["fil_dt"]
    }

    contributions =
      classified
      |> Enum.reject(fn {invoice, _table} -> is_nil(invoice["id"]) end)
      |> Enum.group_by(fn {invoice, _table} -> invoice["id"] end)
      |> Enum.flat_map(fn
        {source_id, [{invoice, table}]} ->
          [
            {source_id,
             %{
               table: table,
               entry: Map.fetch!(entries, invoice),
               effect: Invoice.document_effect(invoice)
             }}
          ]

        {_ambiguous_id, _invoices} ->
          []
      end)
      |> Map.new()

    %{derived: derived, contributions: contributions}
  end

  defp contribution_entry(invoice, table, seller_state) do
    pos = effective_place_of_supply(invoice)

    case table do
      "b2b" ->
        derive_invoice(invoice, seller_state)

      "b2cl" ->
        Map.put(derive_b2cl_invoice(invoice, seller_state), "pos", pos)

      "cdnr" ->
        derive_note(invoice, seller_state)

      "cdnur" ->
        derive_note(invoice, seller_state)
        |> Map.drop(["rchrg", "inv_typ"])
        |> Map.put("typ", "B2CL")

      "exp" ->
        invoice
        |> derive_export_invoice(seller_state)
        |> Map.put("exp_typ", if(Invoice.without_payment?(invoice), do: "WOPAY", else: "WPAY"))

      "b2cs" ->
        %{
          "typ" => "OE",
          "pos" => pos,
          "sply_ty" => if(pos == seller_state, do: "INTRA", else: "INTER"),
          "itms" => derive_items(invoice, seller_state, pos)
        }

      "nil" ->
        %{
          "typ" => Invoice.supply_type(invoice),
          "pos" => pos,
          "itms" => [%{"txval" => round2(invoice_taxable(invoice))}]
        }
    end
  end

  defp derive_b2b(invoices, entries) do
    invoices
    |> Enum.group_by(& &1["buyer_gstin"])
    |> Enum.map(fn {ctin, buyer_invoices} ->
      %{
        "ctin" => ctin,
        "inv" =>
          Enum.map(
            Enum.sort_by(buyer_invoices, &Documents.sort_key(Invoice.document_number(&1))),
            &Map.fetch!(entries, &1)
          )
      }
    end)
    |> Enum.sort_by(& &1["ctin"])
  end

  defp derive_exports(invoices, entries) do
    invoices
    |> Enum.group_by(&if(Invoice.without_payment?(&1), do: "WOPAY", else: "WPAY"))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {payment, invoices} ->
      %{
        "exp_typ" => payment,
        "inv" => Enum.map(invoices, &Map.delete(Map.fetch!(entries, &1), "exp_typ"))
      }
    end)
  end

  defp derive_export_invoice(invoice, seller_state) do
    %{
      "inum" => Invoice.document_number(invoice),
      "idt" => normalize_date(Invoice.document_date(invoice)),
      "val" => document_value(invoice),
      "itms" =>
        invoice
        |> derive_items(seller_state, nil)
        |> Enum.map(&Map.take(&1["itm_det"], ~w(txval rt iamt csamt)))
    }
  end

  defp derive_nil_supplies(invoices, entries) do
    {rows, entries} =
      invoices
      |> Enum.group_by(fn invoice ->
        location =
          if state_code(invoice["seller_gstin"]) == effective_place_of_supply(invoice),
            do: "INTRA",
            else: "INTR"

        location <>
          if(Invoice.recipient_registration(invoice) == "registered", do: "B2B", else: "B2C")
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_reduce(entries, fn {category, documents}, entries ->
        Enum.reduce(
          documents,
          {%{"sply_ty" => category, "nil_amt" => 0.0, "expt_amt" => 0.0, "ngsup_amt" => 0.0},
           entries},
          fn document, {row, entries} ->
            field =
              %{"nil_rated" => "nil_amt", "exempt" => "expt_amt", "non_gst" => "ngsup_amt"}[
                Invoice.supply_type(document)
              ]

            effect = Invoice.document_effect(document)
            amount = round2(row[field] + effect * invoice_taxable(document))
            # Capture the paise this document adds to the rounded portal row.
            contribution = round2((amount - row[field]) * effect)

            entries =
              Map.update!(entries, document, &Map.put(&1, "itms", [%{"txval" => contribution}]))

            {Map.put(row, field, amount), entries}
          end
        )
      end)

    {%{"inv" => rows}, entries}
  end

  defp derive_b2cl(invoices, entries) do
    invoices
    |> Enum.group_by(&effective_place_of_supply/1)
    |> Enum.map(fn {pos, pos_invoices} ->
      %{
        "pos" => pos,
        "inv" =>
          Enum.map(
            Enum.sort_by(pos_invoices, &Documents.sort_key(Invoice.document_number(&1))),
            &Map.delete(Map.fetch!(entries, &1), "pos")
          )
      }
    end)
    |> Enum.sort_by(& &1["pos"])
  end

  defp derive_b2cs(invoices, entries) do
    invoices
    |> Enum.flat_map(fn invoice ->
      pos = effective_place_of_supply(invoice)
      supply_type = Map.fetch!(entries, invoice)["sply_ty"]

      entries
      |> Map.fetch!(invoice)
      |> Map.fetch!("itms")
      |> Enum.map(fn item ->
        detail = item["itm_det"] || %{}

        detail =
          Map.new(detail, fn {key, value} ->
            {key,
             if(key in ~w(txval iamt camt samt csamt),
               do: value * Invoice.document_effect(invoice),
               else: value
             )}
          end)

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

  defp derive_cdnr(notes, entries) do
    notes
    |> Enum.group_by(& &1["buyer_gstin"])
    |> Enum.map(fn {ctin, buyer_notes} ->
      %{
        "ctin" => ctin,
        "nt" =>
          Enum.map(
            Enum.sort_by(buyer_notes, &Documents.sort_key(Invoice.document_number(&1))),
            &Map.fetch!(entries, &1)
          )
      }
    end)
    |> Enum.sort_by(& &1["ctin"])
  end

  defp derive_invoice(invoice, seller_state) do
    pos = effective_place_of_supply(invoice)

    %{
      "inum" => Invoice.document_number(invoice),
      "idt" => normalize_date(Invoice.document_date(invoice)),
      "val" => document_value(invoice),
      "pos" => pos,
      "rchrg" => if(Invoice.reverse_charge?(invoice), do: "Y", else: "N"),
      "inv_typ" =>
        if(Invoice.supply_type(invoice) == "sez",
          do: if(Invoice.without_payment?(invoice), do: "SEWOP", else: "SEWP"),
          else: "R"
        ),
      "itms" => derive_items(invoice, seller_state, pos)
    }
  end

  defp derive_b2cl_invoice(invoice, seller_state) do
    pos = effective_place_of_supply(invoice)

    %{
      "inum" => Invoice.document_number(invoice),
      "idt" => normalize_date(Invoice.document_date(invoice)),
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
      "nt_num" => Invoice.document_number(note),
      "nt_dt" => normalize_date(Invoice.document_date(note)),
      "ntty" => note_type(Invoice.document_type(note)),
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
        document_bucket_tax(document, lines, rate, seller_state, place_of_supply)

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

  defp document_value(document) do
    if TaxDetermination.from_invoice(document).preserve_invoice_value? do
      round2(document["printed_grand_total"])
    else
      tax = if Invoice.tax_excluded_from_total?(document), do: 0, else: invoice_tax(document)
      round2(invoice_taxable(document) + tax)
    end
  end

  defp document_bucket_tax(document, lines, rate, seller_state, pos) do
    cond do
      not TaxDetermination.from_invoice(document).calculate_from_taxable? ->
        TaxDetermination.working_tax(lines)

      Invoice.without_payment?(document) ->
        %{txval: round2(sum(lines, "taxable_value")), camt: 0, samt: 0, iamt: 0}

      Invoice.zero_rated?(document) ->
        computed_bucket_tax(lines, rate, :interstate)

      true ->
        computed_bucket_tax(lines, rate, invoice_tax_mode(lines, seller_state, pos))
    end
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
    |> Enum.reject(&TaxDetermination.unresolved?/1)
    |> Enum.filter(&Invoice.taxable_values_complete?/1)
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
    effect = Invoice.document_effect(document)

    document["line_items"]
    |> List.wrap()
    |> Enum.group_by(&{hsn_code(&1["hsn_sac"]), line_rate(&1)})
    |> Enum.map(fn {{hsn, rate}, lines} ->
      tax =
        if Invoice.zero_rated?(document) or
             not TaxDetermination.from_invoice(document).calculate_from_taxable? do
          document_bucket_tax(
            document,
            lines,
            rate,
            state_code(document["seller_gstin"]),
            effective_place_of_supply(document)
          )
        else
          intra = mode_tax(lines, rate, :intrastate)
          inter = mode_tax(lines, rate, :interstate)
          %{camt: intra.camt, samt: intra.samt, iamt: inter.iamt}
        end

      txval = effect * round2(sum(lines, "taxable_value"))
      camt = effect * tax.camt
      samt = effect * tax.samt
      iamt = effect * tax.iamt

      %{
        "inum" => Invoice.document_number(document),
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
      tax = document_bucket_tax(invoice, lines, rate, seller_state, pos)

      %{
        "hsn_sc" => hsn,
        "rt" => rate,
        "uqc" => uqc,
        "qty" => sum(lines, "quantity") * Invoice.document_effect(invoice),
        "txval" => tax.txval * Invoice.document_effect(invoice),
        "camt" => tax.camt * Invoice.document_effect(invoice),
        "samt" => tax.samt * Invoice.document_effect(invoice),
        "iamt" => tax.iamt * Invoice.document_effect(invoice),
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
  Taxable and tax by rate across the month, summed from the supported return tables — the
  buckets are the very `itm_det`s the portal receives, never regrouped from the
  invoices — with `"contribs"` naming each bucket's contributors, and what each
  invoice put into the bucket, for the workings screen to open.
  """
  def rate_summary(derived) do
    derived
    |> Map.delete("nil")
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
    export_details =
      for block <- derived["exp"] || [],
          invoice <- block["inv"] || [],
          item <- invoice["itms"] || [],
          do: %{number: invoice["inum"], type: "invoice", detail: item}

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

    unregistered_details =
      for note <- derived["cdnur"] || [],
          item <- note["itms"] || [],
          do: %{
            number: note["nt_num"],
            type: note_document_type(note["ntty"]),
            detail: scale_detail(item["itm_det"] || %{}, note_effect(note["ntty"]))
          }

    nil_details =
      for row <- get_in(derived, ["nil", "inv"]) || [],
          do: %{
            number: "Table 8 #{row["sply_ty"]}",
            type: "invoice",
            detail: %{
              "rt" => 0,
              "txval" => num(row["nil_amt"]) + num(row["expt_amt"]) + num(row["ngsup_amt"]),
              "camt" => 0,
              "samt" => 0,
              "iamt" => 0,
              "csamt" => 0
            }
          }

    export_details ++
      invoice_details ++
      b2cl_details ++ b2cs_details ++ credit_details ++ unregistered_details ++ nil_details
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

  defp invoice_taxable(invoice), do: sum(invoice["line_items"], "taxable_value")

  defp invoice_tax(invoice) do
    if not TaxDetermination.from_invoice(invoice).calculate_from_taxable? do
      tax = TaxDetermination.working_tax(invoice["line_items"] || [])
      tax.camt + tax.samt + tax.iamt
    else
      ordinary_invoice_tax(invoice)
    end
  end

  defp ordinary_invoice_tax(invoice) do
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
    case Dates.parse_date(to_string(date)) do
      %Date{} = parsed -> normalize_date(parsed)
      nil -> date |> to_string() |> String.trim() |> String.replace(~r/[.\/]/, "-")
    end
  end

  defp hsn_code(nil), do: nil
  defp hsn_code(hsn), do: hsn |> to_string() |> String.replace(~r/\D/, "")

  @doc "The place of supply used in the filing projection."
  def filing_place_of_supply(invoice), do: effective_place_of_supply(invoice)

  defp effective_place_of_supply(invoice) do
    case invoice["place_of_supply"] do
      pos when is_binary(pos) -> if(StateCodes.name_for(pos), do: pos)
      _missing -> state_code(invoice["buyer_gstin"])
    end
  end

  defp b2c_interstate_table(invoice) do
    case parsed_document_date(Invoice.document_date(invoice)) do
      %Date{} = date ->
        threshold = if Date.before?(date, ~D[2024-08-01]), do: 250_000, else: 100_000
        if document_value(invoice) > threshold, do: "b2cl", else: "b2cs"

      nil ->
        nil
    end
  end

  defp parsed_document_date(%Date{} = date), do: date
  defp parsed_document_date(value) when is_binary(value), do: Dates.parse_date(value)
  defp parsed_document_date(_value), do: nil

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

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp first_present(invoices, field), do: Enum.find_value(invoices, & &1[field])
end
