defmodule Nila.Gst.Sales.Gstr1.Readiness do
  @moduledoc "GSTR-1 output capabilities layered over intrinsic invoice readiness."

  alias Nila.Gst.{InvoiceFacts, Issues}
  alias Nila.Gst.Sales.{Invoice, OutputCapabilities, OutputIssues}

  @doc "Flags invoices outside the explicitly selected sales working period."
  def period_issues(invoices, period) when is_binary(period) do
    Enum.flat_map(invoices, fn invoice ->
      date =
        case invoice["invoice_date"] do
          %Date{} = date ->
            date

          text when is_binary(text) ->
            case Date.from_iso8601(text) do
              {:ok, date} -> date
              _ -> nil
            end

          _ ->
            nil
        end

      if date && Calendar.strftime(date, "%Y-%m") != period do
        [
          %{
            "code" => "invoice_period_mismatch",
            "level" => "blocking",
            "source_id" => Invoice.source_id(invoice),
            "invoice_number" => invoice["invoice_number"],
            "fields" => ["invoice_date"],
            "message" =>
              "Invoice dated #{Date.to_iso8601(date)} is outside the #{period} working. Correct the extracted date or exclude this invoice; cross-period reporting is not supported yet."
          }
        ]
      else
        []
      end
    end)
  end

  def period_issues(_invoices, _period), do: []

  @doc "Unsupported document treatments and duplicate active invoice numbers."
  def blocking_issues(invoices) do
    capability_issues(invoices) ++
      Nila.Gst.Sales.Invoice.Validation.duplicate_number_issues(invoices)
  end

  @messages %{
    "missing_tax_payment" =>
      "Confirm whether this export or SEZ supply is with payment of IGST or without payment under LUT/bond.",
    "special_supply_conflict" =>
      "Resolve the recipient, supply treatment and reverse-charge evidence before filing this document.",
    "special_note_unsupported" =>
      "Export, SEZ and reverse-charge credit/debit notes are not supported yet.",
    "non_taxable_tax_conflict" =>
      "This document is marked nil-rated, exempt or non-GST but also carries GST. Resolve the supply treatment and tax evidence before filing.",
    "missing_original_sale_category" =>
      "Confirm whether the original interstate sale was B2C Other / Small or B2C Large. The note's own value does not determine this.",
    "cancelled_document_unsupported" =>
      "this document is cancelled; Nila accounts for its number but does not yet derive cancellation filing treatment",
    "amendment_document_unsupported" =>
      "this document amends a prior filing, and Nila does not yet derive amendment tables"
  }

  def issues(invoices) when is_list(invoices) do
    invoices
    |> capability_issues()
    |> Enum.concat(OutputIssues.cess(invoices))
    |> Issues.normalize_all()
  end

  @doc "GSTR-1 capability blockers without shared cess checks."
  def capability_issues(invoices) when is_list(invoices) do
    Enum.flat_map(invoices, fn invoice ->
      invoice = InvoiceFacts.sales!(invoice)

      invoice
      |> OutputCapabilities.common()
      |> Enum.reject(
        &(&1.code in ~w(nil_rated_supply_unsupported exempt_supply_unsupported non_gst_supply_unsupported export_supply_unsupported sez_supply_unsupported outward_reverse_charge_unsupported))
      )
      |> maybe_add_special(invoice)
      |> maybe_add_non_taxable_conflict(invoice)
      |> maybe_add_cdnur(invoice)
      |> Enum.map(&issue(invoice, &1.code, &1.fields))
    end)
  end

  defp maybe_add_special(findings, invoice) do
    zero? = Invoice.zero_rated?(invoice)
    rcm? = Invoice.reverse_charge?(invoice)

    checks = [
      {zero? and invoice.evidence["tax_payment"] not in ~w(with_payment without_payment),
       "missing_tax_payment", ["tax_payment"]},
      {(zero? or rcm?) and invoice.document_type in ~w(credit_note debit_note),
       "special_note_unsupported", ["document_type"]},
      {Invoice.special_supply_conflict?(invoice), "special_supply_conflict",
       ["supply_type", "tax_payment", "reverse_charge", "recipient_registration", "buyer_gstin"]}
    ]

    findings ++ for {true, code, fields} <- checks, do: %{code: code, fields: fields}
  end

  defp maybe_add_cdnur(findings, invoice) do
    note? = invoice.document_type in ~w(credit_note debit_note)

    seller_state =
      invoice.issuer && invoice.issuer.gstin && String.slice(invoice.issuer.gstin, 0, 2)

    if note? and Invoice.supply_type(invoice) == "taxable" and
         OutputCapabilities.recipient_registration(invoice) == "unregistered" and
         invoice.place_of_supply != seller_state and
         invoice.evidence["original_sale_category"] not in ~w(b2cs b2cl) do
      findings ++
        [%{code: "missing_original_sale_category", fields: ["original_sale_category"]}]
    else
      findings
    end
  end

  defp maybe_add_non_taxable_conflict(findings, invoice) do
    if Invoice.supply_type(invoice) in ~w(nil_rated exempt non_gst) and
         (Enum.any?(Map.values(invoice.tax_paise), &(is_integer(&1) and &1 != 0)) or
            (invoice
             |> InvoiceFacts.to_sales_map()
             |> Nila.Gst.TaxComponents.printed_tax_total()) not in [nil, 0] or
            Enum.any?(invoice.lines, fn line ->
              Enum.any?(
                [line.cgst_rate, line.sgst_rate, line.igst_rate],
                &(&1 && Decimal.compare(&1, 0) != :eq)
              )
            end)) do
      tax_fields =
        for {_line, index} <- Enum.with_index(invoice.lines),
            field <- ~w(cgst_rate sgst_rate igst_rate cgst_amount sgst_amount igst_amount),
            do: "line_items[#{index}].#{field}"

      findings ++
        [
          %{
            code: "non_taxable_tax_conflict",
            fields: ["supply_type", "printed_total_tax" | tax_fields]
          }
        ]
    else
      findings
    end
  end

  defp issue(invoice, code, fields) do
    %{
      "invoice" => invoice.number,
      "source_id" => invoice.id || invoice.number,
      "code" => code,
      "level" => Issues.level_for(code),
      "message" => Map.fetch!(@messages, code),
      "fields" => fields
    }
  end
end
