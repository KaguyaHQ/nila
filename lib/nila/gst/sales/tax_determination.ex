defmodule Nila.Gst.Sales.TaxDetermination do
  @moduledoc """
  The tax result consumed by validation and outputs.

  Valuation and amount origin are separate: RSP may apply even when the amount
  was established from an invoice residual rather than an available retail price.
  Amounts remain on the working lines; this view never keeps a second copy.
  Ordinary invoices retain their existing calculation and validation paths.
  """

  alias Nila.Gst.Sales.RspValuation

  defstruct regime: :transaction_value,
            status: :ordinary,
            amount_origin: :taxable_value,
            calculate_from_taxable?: true,
            independent_invoice_total?: true,
            preserve_invoice_value?: false,
            reconciliation: nil,
            unresolved_issue: nil

  def prepare(invoices, reports), do: RspValuation.apply(invoices, reports)
  def reset(invoice), do: RspValuation.reset(invoice)

  def from_invoice(invoice), do: from_result(invoice["tax_valuation"])

  defp from_result(%{"basis" => "rsp"} = result) do
    resolved? = result["status"] == "derived"

    origin =
      case {resolved?, result["method"]} do
        {true, "invoice_value_residual"} -> :invoice_value_residual
        {true, "reviewer_entered"} -> :reviewer_entered
        _ -> :unresolved
      end

    %__MODULE__{
      regime: :rsp,
      status: if(resolved?, do: :resolved, else: :unresolved),
      amount_origin: origin,
      calculate_from_taxable?: false,
      independent_invoice_total?: origin != :invoice_value_residual,
      preserve_invoice_value?: resolved?,
      reconciliation: result["reconciliation"],
      unresolved_issue:
        if(not resolved?,
          do: %{
            code: "rsp_tax_unresolved",
            message:
              "GST is based on retail sale price for these goods. The report does not establish the tax amounts for this document; the supplied HSN summary does not support a reconciled derivation."
          }
        )
    }
  end

  defp from_result(_), do: %__MODULE__{}

  def unresolved?(invoice), do: from_invoice(invoice).status == :unresolved

  @doc "Sums working amounts for outputs; unresolved records remain excluded from filing."
  def working_tax(lines) do
    for {target, field} <- [
          txval: "taxable_value",
          camt: "cgst_amount",
          samt: "sgst_amount",
          iamt: "igst_amount"
        ],
        into: %{} do
      values = Enum.map(lines, & &1[field])
      total = Float.round(Enum.sum(Enum.filter(values, &is_number/1)) * 1.0, 2)
      {target, total}
    end
  end
end
