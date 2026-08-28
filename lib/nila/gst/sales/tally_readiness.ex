defmodule Nila.Gst.Sales.TallyReadiness do
  @moduledoc "Capabilities required to represent an invoice faithfully in Nila's Tally voucher."

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.{Invoice, OutputIssues}

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
    |> Enum.flat_map(&capability_issues/1)
    |> Enum.concat(OutputIssues.cess(invoices))
    |> Issues.normalize_all()
  end

  defp capability_issues(invoice) do
    document = invoice["document"] || %{}
    supply_type = invoice["supply_type"] || if(document["export"], do: "export", else: "taxable")
    document_status = invoice["document_status"] || "active"

    [
      {document["export"] || supply_type == "export", "export_supply_unsupported",
       ["supply_type"]},
      {supply_type == "sez", "sez_supply_unsupported", ["supply_type"]},
      {supply_type == "nil_rated", "nil_rated_supply_unsupported", ["supply_type"]},
      {supply_type == "exempt", "exempt_supply_unsupported", ["supply_type"]},
      {supply_type == "non_gst", "non_gst_supply_unsupported", ["supply_type"]},
      {document["reverse_charge"] == true, "outward_reverse_charge_unsupported",
       ["invoice_number"]},
      {document_status == "cancelled", "cancelled_document_unsupported", ["document_status"]},
      {document_status == "amendment", "amendment_document_unsupported", ["document_status"]}
    ]
    |> Enum.filter(fn {present?, _code, _fields} -> present? == true end)
    |> Enum.map(fn {_present?, code, fields} -> issue(invoice, code, fields) end)
  end

  defp issue(invoice, code, fields) do
    %{
      "invoice" => invoice["invoice_number"],
      "source_id" => Invoice.source_id(invoice),
      "code" => code,
      "level" => Issues.level_for(code),
      "message" => Map.fetch!(@messages, code),
      "fields" => fields
    }
  end
end
