defmodule Nila.Gst.Sales.Account do
  @moduledoc "Pure source-to-draft control account for one effective GSTR-1 month."

  alias Nila.Gst.Sales.Gstr1

  @tax_heads ~w(igst cgst sgst)

  def summarize(source_invoices, active_invoices, issues, derived, source) do
    extracted_totals = extracted_totals(active_invoices)
    draft_totals = draft_totals(derived)
    required = Enum.filter(issues, &required?/1)

    %{
      source: %{
        files: Map.fetch!(source, :files),
        pages_read: Map.get(source, :pages_read)
      },
      extraction: %{
        documents: length(source_invoices),
        active_documents: length(active_invoices),
        duplicate_copies: length(source_invoices) - length(active_invoices),
        unique_invoice_numbers: unique_invoice_numbers(active_invoices),
        series: Gstr1.series_account(active_invoices),
        totals: extracted_totals
      },
      draft: %{
        documents: draft_document_count(derived),
        totals: draft_totals
      },
      differences: totals_difference(draft_totals, extracted_totals),
      issues: %{
        required: required,
        required_count: length(required),
        informational_count: Enum.count(issues, &informational?/1)
      }
    }
  end

  defp required?(issue),
    do: issue["status"] == "open" and issue["level"] != "info"

  defp informational?(issue),
    do: issue["status"] == "open" and issue["level"] == "info"

  defp unique_invoice_numbers(invoices) do
    invoices
    |> Enum.map(& &1["invoice_number"])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> MapSet.new()
    |> MapSet.size()
  end

  defp extracted_totals(invoices) do
    invoices
    |> Enum.flat_map(&List.wrap(&1["line_items"]))
    |> Enum.reduce(empty_totals(), fn line, totals ->
      taxable = number(line["taxable_value"])
      igst = number(line["igst_amount"])
      cgst = number(line["cgst_amount"])
      sgst = number(line["sgst_amount"])

      totals
      |> Map.update!(:taxable, &(&1 + taxable))
      |> Map.update!(:igst, &(&1 + igst))
      |> Map.update!(:cgst, &(&1 + cgst))
      |> Map.update!(:sgst, &(&1 + sgst))
      |> Map.update!(:tax, &(&1 + igst + cgst + sgst))
    end)
  end

  defp draft_totals(nil), do: empty_totals()

  defp draft_totals(derived) do
    derived
    |> draft_details()
    |> Enum.reduce(empty_totals(), fn detail, totals ->
      igst = number(detail["iamt"])
      cgst = number(detail["camt"])
      sgst = number(detail["samt"])

      totals
      |> Map.update!(:taxable, &(&1 + number(detail["txval"])))
      |> Map.update!(:igst, &(&1 + igst))
      |> Map.update!(:cgst, &(&1 + cgst))
      |> Map.update!(:sgst, &(&1 + sgst))
      |> Map.update!(:tax, &(&1 + igst + cgst + sgst))
    end)
  end

  defp draft_document_count(nil), do: 0

  defp draft_document_count(derived) do
    derived
    |> Map.get("b2b", [])
    |> Enum.reduce(0, &(length(&1["inv"] || []) + &2))
  end

  defp draft_details(derived) do
    derived
    |> Map.get("b2b", [])
    |> Enum.flat_map(&List.wrap(&1["inv"]))
    |> Enum.flat_map(&List.wrap(&1["itms"]))
    |> Enum.map(&(&1["itm_det"] || %{}))
  end

  defp totals_difference(draft, extracted) do
    Map.new(["taxable" | @tax_heads] ++ ["tax"], fn head ->
      key = String.to_existing_atom(head)
      {key, Float.round(number(draft[key]) - number(extracted[key]), 2)}
    end)
    |> Map.put(:cess, nil)
  end

  defp empty_totals,
    do: %{taxable: 0.0, igst: 0.0, cgst: 0.0, sgst: 0.0, cess: nil, tax: 0.0}

  defp number(value) when is_integer(value), do: value * 1.0
  defp number(value) when is_float(value), do: value
  defp number(nil), do: 0.0
end
