defmodule Nila.Gst.Sales.OutputCapabilities do
  @moduledoc """
  Shared capability facts for sales outputs.

  This module answers only whether a document carries a treatment that current
  outputs must handle deliberately. GSTR-1 and Tally retain their own messages
  and destination-specific capabilities.
  """

  alias Nila.Gst.InvoiceFacts

  @type finding :: %{code: String.t(), fields: [String.t()]}

  @doc "Treatments whose support boundary is currently shared by GSTR-1 and Tally."
  @spec common(InvoiceFacts.t() | map()) :: [finding()]
  def common(invoice) do
    invoice = InvoiceFacts.sales!(invoice)
    document = invoice.evidence["document"] || %{}
    supply_type = supply_type(invoice)
    document_status = document_status(invoice)

    [
      {document["export"] == true or supply_type == "export", "export_supply_unsupported",
       ["supply_type"]},
      {supply_type == "sez", "sez_supply_unsupported", ["supply_type"]},
      {supply_type == "nil_rated", "nil_rated_supply_unsupported", ["supply_type"]},
      {supply_type == "exempt", "exempt_supply_unsupported", ["supply_type"]},
      {supply_type == "non_gst", "non_gst_supply_unsupported", ["supply_type"]},
      {Nila.Gst.Sales.Invoice.reverse_charge?(invoice), "outward_reverse_charge_unsupported",
       ["reverse_charge"]},
      {document_status == "cancelled", "cancelled_document_unsupported", ["document_status"]},
      {document_status == "amendment", "amendment_document_unsupported", ["document_status"]}
    ]
    |> Enum.filter(fn {present?, _code, _fields} -> present? end)
    |> Enum.map(fn {_present?, code, fields} -> %{code: code, fields: fields} end)
  end

  @doc false
  def supply_type(invoice) do
    invoice.evidence["supply_type"] ||
      if(get_in(invoice.evidence, ["document", "export"]), do: "export", else: "taxable")
  end

  @doc false
  def document_status(invoice), do: invoice.evidence["document_status"] || "active"

  @doc false
  def recipient_registration(invoice) do
    invoice.evidence["recipient_registration"] ||
      if(is_nil(recipient_gstin(invoice)), do: "unknown", else: "registered")
  end

  defp recipient_gstin(%{recipient: nil}), do: nil
  defp recipient_gstin(invoice), do: invoice.recipient.gstin
end
