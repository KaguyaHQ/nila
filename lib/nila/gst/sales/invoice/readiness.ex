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

  @doc "Review outcomes for an annotated invoice, optionally checked against its batch."
  def outcomes(invoice, batch \\ nil) do
    lines = List.wrap(invoice["line_items"])
    hsn_issues = Validation.sales_issues([invoice])
    inferred_issues = Validation.summary_issues([invoice])

    directory_checked? =
      lines != [] and
        Enum.all?(lines, fn line ->
          get_in(line, ["hsn_validation", "status"]) in ~w(valid missing incomplete invalid)
        end)

    hsn = %{
      id: "hsn_directory",
      label: "HSN/SAC codes exist in the directory",
      detail:
        "Checked against the active HSN/SAC directory; this does not establish that a code is correct for the item.",
      status:
        cond do
          hsn_issues != [] -> :failed
          directory_checked? -> :passed
          true -> :not_checked
        end,
      issues: hsn_issues
    }

    inferred = %{
      id: "hsn_inferred",
      label: "Inferred HSN/SAC needs confirmation",
      detail: "Codes inferred instead of read from the bill require a reviewer.",
      status: if(inferred_issues == [], do: :not_applicable, else: :failed),
      issues: inferred_issues
    }

    duplicate_issues =
      if is_list(batch) do
        batch
        |> Enum.map(fn candidate ->
          if Nila.Gst.Sales.Invoice.source_id(candidate) ==
               Nila.Gst.Sales.Invoice.source_id(invoice), do: invoice, else: candidate
        end)
        |> InvoiceValidation.duplicate_number_issues()
        |> Enum.filter(&(Nila.Gst.Sales.Invoice.source_id(invoice) in &1["source_ids"]))
      else
        []
      end

    duplicate = %{
      id: "duplicate_number",
      label: "No duplicate invoice number in this batch",
      detail: "Compared document type and invoice number with the other invoices in this batch.",
      status:
        cond do
          duplicate_issues != [] ->
            :failed

          not is_list(batch) or is_nil(invoice["invoice_number"]) or
              String.trim(invoice["invoice_number"]) == "" ->
            :not_checked

          not Enum.any?(
            batch,
            &(Nila.Gst.Sales.Invoice.source_id(&1) == Nila.Gst.Sales.Invoice.source_id(invoice))
          ) ->
            :not_checked

          true ->
            :passed
        end,
      issues: duplicate_issues
    }

    InvoiceValidation.outcomes(invoice) ++ [hsn, inferred, duplicate]
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
