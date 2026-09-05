defmodule Nila.Gst.Sales.TallyReadiness do
  @moduledoc "Capabilities required to represent an invoice faithfully in Nila's Tally voucher."

  alias Nila.Gst.{InvoiceFacts, Issues}
  alias Nila.Gst.Sales.{OutputCapabilities, OutputIssues}

  @irrelevant_invoice_issue_codes ~w(
    tax_split_mismatch tax_treatment_uncertain missing_place_of_supply invalid_place_of_supply
  )

  @messages %{
    "export_supply_unsupported" =>
      "Nila's current Tally voucher does not carry export treatment.",
    "sez_supply_unsupported" => "Nila's current Tally voucher does not carry SEZ treatment.",
    "nil_rated_supply_unsupported" =>
      "Nila's current Tally voucher cannot mark this supply as nil-rated.",
    "exempt_supply_unsupported" =>
      "Nila's current Tally voucher cannot mark this supply as exempt.",
    "non_gst_supply_unsupported" =>
      "Nila's current Tally voucher cannot mark this as a non-GST supply.",
    "outward_reverse_charge_unsupported" =>
      "Nila's current Tally voucher does not carry outward reverse-charge treatment.",
    "cancelled_document_unsupported" =>
      "A cancelled document must not be created as a new Tally voucher.",
    "amendment_document_unsupported" =>
      "Nila's current Tally voucher cannot link an amendment to the original voucher."
  }

  def issues(invoices) when is_list(invoices) do
    invoices
    |> Enum.flat_map(fn invoice ->
      invoice = InvoiceFacts.sales!(invoice)
      Enum.map(OutputCapabilities.common(invoice), &issue(invoice, &1.code, &1.fields))
    end)
    |> Enum.concat(OutputIssues.cess(invoices))
    |> Issues.normalize_all()
  end

  @doc "Whether an intrinsic invoice issue requires attention before creating a Tally voucher."
  def relevant_invoice_issue?(%{"code" => code}),
    do: code not in @irrelevant_invoice_issue_codes

  def relevant_invoice_issue?(_issue), do: true

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
