defmodule Nila.Gst.Sales.Gstr1Readiness do
  @moduledoc "GSTR-1 output capabilities layered over intrinsic invoice readiness."

  alias Nila.Gst.{InvoiceFacts, Issues}
  alias Nila.Gst.Sales.{OutputCapabilities, OutputIssues}

  @messages %{
    "export_supply_unsupported" =>
      "this document is an export supply, and GSTR-1 derivation has no exp table",
    "sez_supply_unsupported" =>
      "this document is an SEZ supply, and GSTR-1 derivation has no SEZ treatment",
    "nil_rated_supply_unsupported" =>
      "this document is nil-rated, and GSTR-1 derivation has no nil-supply table",
    "exempt_supply_unsupported" =>
      "this document is exempt, and GSTR-1 derivation has no exempt-supply table",
    "non_gst_supply_unsupported" =>
      "this document is non-GST, and GSTR-1 derivation has no non-GST table",
    "outward_reverse_charge_unsupported" =>
      "this bill says the recipient pays the tax, and derivation files every invoice rchrg \"N\"",
    "cdnur_unsupported" =>
      "this is a note to an unregistered recipient, and GSTR-1 derivation has no cdnur table",
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
      |> maybe_add_cdnur(invoice)
      |> Enum.map(&issue(invoice, &1.code, &1.fields))
    end)
  end

  defp maybe_add_cdnur(findings, invoice) do
    note? = invoice.document_type in ~w(credit_note debit_note)

    if note? and OutputCapabilities.recipient_registration(invoice) == "unregistered" do
      findings ++
        [%{code: "cdnur_unsupported", fields: ["recipient_registration", "buyer_gstin"]}]
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
