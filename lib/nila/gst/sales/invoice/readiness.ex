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
  alias Nila.Gst.RateHistory
  alias Nila.Gst.Rates.Validation, as: RateValidation
  alias Nila.Gst.Sales.Invoice.Validation, as: InvoiceValidation

  @doc "Annotates invoices with the active HSN and statutory-rate directories."
  def annotate(invoices, compliance \\ %{}) when is_list(invoices) do
    invoices
    |> annotate_hsn(compliance)
    |> annotate_rates(compliance)
  end

  @doc "Returns annotated invoices and every normalized invoice-level issue."
  def evaluate(invoices, compliance \\ %{}) when is_list(invoices) do
    invoices = annotate(invoices, compliance)

    %{invoices: invoices, issues: issues(invoices, compliance)}
  end

  @doc "Returns issues for invoices already annotated by `annotate/2`."
  def issues(invoices, compliance \\ %{}) when is_list(invoices) do
    invoices
    |> InvoiceValidation.issues()
    |> Enum.concat(InvoiceValidation.duplicate_number_issues(invoices))
    |> Enum.concat(compliance_issues(invoices, compliance))
    |> Issues.normalize_all()
  end

  defp annotate_hsn(invoices, %{directory: directory}) do
    invoices
    |> Validation.annotate_invoices(directory)
    |> DescriptionSignal.observe(%{track: :sales})
  end

  defp annotate_hsn(invoices, _compliance), do: invoices

  defp annotate_rates(invoices, %{rate_directory: directory}),
    do: RateValidation.annotate_invoices(invoices, directory)

  defp annotate_rates(invoices, _compliance), do: invoices

  defp compliance_issues(invoices, compliance) do
    # Missing HSN/SAC is knowable without a directory. Exact-code validity is
    # added by `annotate/2` whenever an active directory exists.
    hsn_issues = Validation.sales_issues(invoices)

    statutory_issues =
      if compliance[:rate_directory], do: RateValidation.sales_issues(invoices), else: []

    hsn_issues ++
      statutory_issues ++
      history_issues(invoices, compliance)
  end

  defp history_issues(invoices, %{rate_history_by_period: history_by_period})
       when is_map(history_by_period) do
    invoices
    |> Enum.group_by(&invoice_period/1)
    |> Enum.flat_map(fn {period, period_invoices} ->
      history = Map.get(history_by_period, period, [])

      Validation.summary_issues(period_invoices, history) ++
        RateHistory.issues(period_invoices, history)
    end)
  end

  defp history_issues(invoices, compliance) do
    history = compliance[:rate_history] || []
    Validation.summary_issues(invoices, history) ++ RateHistory.issues(invoices, history)
  end

  defp invoice_period(%{"invoice_date" => %Date{} = date}),
    do: Calendar.strftime(date, "%Y-%m")

  defp invoice_period(%{
         "invoice_date" => <<year::binary-size(4), "-", month::binary-size(2), _rest::binary>>
       }),
       do: year <> "-" <> month

  defp invoice_period(_invoice), do: nil
end
