defmodule Nila.Gst.Sales.Invoice.Readiness do
  @moduledoc """
  The authoritative invoice-level readiness boundary for sales outputs.

  Specialist validators remain small and independent. This module owns their
  composition so a new output cannot accidentally ship with a smaller idea of
  a valid sales invoice. Month completeness and output-specific ledger checks
  live outside this boundary.
  """

  alias Nila.Gst.Hsn.{DescriptionSignal, Validation}
  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.Invoice.Validation, as: InvoiceValidation

  @doc "Annotates invoices with the active HSN directory."
  def annotate(invoices, compliance \\ %{}) when is_list(invoices) do
    annotate_hsn(invoices, compliance)
  end

  @doc "Returns annotated invoices and every normalized invoice-level issue."
  def evaluate(invoices, compliance \\ %{}) when is_list(invoices) do
    invoices = annotate(invoices, compliance)

    %{invoices: invoices, issues: issues(invoices)}
  end

  @doc "Returns issues for invoices already annotated by `annotate/2`."
  def issues(invoices) when is_list(invoices) do
    invoices
    |> InvoiceValidation.issues()
    |> Enum.concat(InvoiceValidation.duplicate_number_issues(invoices))
    |> Enum.concat(compliance_issues(invoices))
    |> Issues.normalize_all()
  end

  defp annotate_hsn(invoices, %{directory: directory}) do
    invoices
    |> Validation.annotate_invoices(directory)
    |> DescriptionSignal.observe(%{track: :sales})
  end

  defp annotate_hsn(invoices, _compliance), do: invoices

  defp compliance_issues(invoices) do
    # Code validity, descriptions and inferred-code review remain independent
    # of whether the printed tax rate is legally applicable to the item.
    Validation.sales_issues(invoices) ++ Validation.summary_issues(invoices)
  end
end
