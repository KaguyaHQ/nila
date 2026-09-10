defmodule Nila.Gst.Sales.Review.Account do
  @moduledoc "Pure source-to-draft control account for one effective GSTR-1 month."

  alias Nila.Gst.Sales.Gstr1.Documents
  alias Nila.Gst.Sales.Invoice
  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.{Gstr1, Workings}

  @tax_heads ~w(igst cgst sgst)
  @components [:taxable, :igst, :cgst, :sgst, :tax]

  def summarize(workings, source) when is_map(workings) do
    source_invoices = workings.source_invoices
    active_invoices = workings.active_invoices
    # `nil` means the snapshot predates this projection — not "same as active".
    # Defaulting to the active invoices made a signed month's "As printed"
    # column render against *today's* invoice set, so the reconciliation a
    # reviewer signed could silently change afterwards. The totals still compute
    # off the active set so nothing downstream divides by a missing number, but
    # `recorded?` says not to believe the column.
    printed_recorded? = not is_nil(Map.get(workings, :printed_active_invoices))
    printed_invoices = Map.get(workings, :printed_active_invoices) || active_invoices
    issues = workings.issues
    derived = workings.derived
    printed_totals = extracted_totals(printed_invoices)
    draft_totals = draft_totals(derived)
    required = Enum.filter(issues, &required?/1)
    advisory = Enum.filter(issues, &advisory?/1)

    %{
      source: %{
        files: Map.fetch!(source, :files),
        pages_read: Map.get(source, :pages_read)
      },
      extraction: %{
        documents: length(source_invoices),
        active_documents: length(active_invoices),
        duplicate_copies: length(source_invoices) - length(active_invoices),
        unresolved_duplicates: unresolved_duplicates(active_invoices),
        unique_invoice_numbers: unique_invoice_numbers(source_invoices),
        series: Documents.account(active_invoices),
        totals: extracted_totals(active_invoices)
      },
      printed: %{
        documents: length(printed_invoices),
        totals: printed_totals,
        recorded?: printed_recorded?
      },
      draft: %{
        documents: draft_document_count(derived, active_invoices),
        totals: draft_totals
      },
      differences: totals_difference(draft_totals, printed_totals),
      causes: issue_causes(issues, source_invoices),
      cess: cess_state(issues),
      issues: %{
        required: required,
        required_count: length(required),
        advisory: advisory,
        advisory_count: length(advisory),
        by_kind: Issues.by_kind(required),
        informational_count: Enum.count(issues, &informational?/1)
      }
    }
  end

  def summarize(source_invoices, active_invoices, issues, derived, source) do
    summarize(
      %{
        source_invoices: source_invoices,
        active_invoices: active_invoices,
        printed_active_invoices: active_invoices,
        issues: issues,
        derived: derived
      },
      source
    )
  end

  defp unresolved_duplicates(invoices) do
    invoices
    |> Enum.map(& &1["invoice_number"])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.reduce(0, fn {_number, count}, total -> total + max(count - 1, 0) end)
  end

  defp issue_causes(issues, source_invoices) do
    numbers_by_id = Map.new(source_invoices, &{&1["id"], &1["invoice_number"]})

    Enum.reduce(issues, Map.new(@components, &{&1, []}), fn issue, causes ->
      components = issue_components(issue)
      source_ids = List.wrap(issue["source_id"] || issue["source_ids"])

      cause = %{
        source_id: List.first(source_ids),
        source_ids: source_ids,
        invoices:
          source_ids
          |> Enum.map(&Map.get(numbers_by_id, &1))
          |> Enum.reject(&is_nil/1)
          |> then(fn numbers ->
            if numbers == [], do: List.wrap(issue["invoice"]), else: numbers
          end)
          |> Enum.uniq(),
        target: Workings.issue_key(issue)
      }

      Enum.reduce(components, causes, fn component, acc ->
        Map.update!(acc, component, fn existing ->
          if cause.invoices == [],
            do: existing,
            else: Enum.uniq_by(existing ++ [cause], & &1.target)
        end)
      end)
    end)
  end

  defp issue_components(issue) do
    fields = List.wrap(issue["fields"])

    components =
      Enum.filter(@components, fn
        :taxable -> Enum.any?(fields, &String.contains?(&1, "taxable"))
        :tax -> Enum.any?(fields, &tax_field?/1)
        component -> Enum.any?(fields, &String.contains?(&1, Atom.to_string(component)))
      end)

    if components == [] and
         issue["code"] in ~w(line_arithmetic grand_total_mismatch bucket_tax_mismatch tax_split_mismatch lopsided_tax_split cgst_sgst_unequal),
       do: [:igst, :cgst, :sgst, :tax],
       else: components
  end

  defp tax_field?(field),
    do: Enum.any?(~w(igst cgst sgst total_tax grand_total), &String.contains?(field, &1))

  # Two states, because the screen settles it: either no line falls under a
  # cess-bearing heading, or one does and this return cannot carry it.
  defp cess_state(issues) do
    if Enum.any?(issues, &(&1["status"] == "open" and &1["code"] == "cess_unsupported")),
      do: :unsupported,
      else: :checked_none
  end

  # What holds up the working: `blocking` and `required`. An
  # advisory is visible context, so it is counted separately and never gates.
  defp required?(issue), do: issue["status"] == "open" and Issues.gating?(issue)

  defp advisory?(issue), do: issue["status"] == "open" and Issues.advisory?(issue)

  defp informational?(issue),
    do: issue["status"] == "open" and Issues.level(issue) == "info"

  defp unique_invoice_numbers(invoices) do
    invoices
    |> Enum.map(& &1["invoice_number"])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> MapSet.new()
    |> MapSet.size()
  end

  defp extracted_totals(invoices) do
    {totals, taxable_complete?} =
      Enum.reduce(invoices, {empty_totals(), true}, fn invoice, {totals, complete?} ->
        effect = Invoice.document_effect(invoice)

        Enum.reduce(List.wrap(invoice["line_items"]), {totals, complete?}, fn line,
                                                                              {totals, complete?} ->
          taxable = line["taxable_value"]
          igst = effect * number(line["igst_amount"])
          cgst = effect * number(line["cgst_amount"])
          sgst = effect * number(line["sgst_amount"])

          totals =
            totals
            |> Map.update!(:taxable, &(&1 + effect * number(taxable)))
            |> Map.update!(:igst, &(&1 + igst))
            |> Map.update!(:cgst, &(&1 + cgst))
            |> Map.update!(:sgst, &(&1 + sgst))
            |> Map.update!(:tax, &(&1 + igst + cgst + sgst))

          {totals, complete? and is_number(taxable)}
        end)
      end)

    if taxable_complete?, do: totals, else: %{totals | taxable: nil}
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

  defp draft_document_count(nil, _active_invoices), do: 0

  defp draft_document_count(derived, active_invoices) do
    invoice_level =
      Enum.reduce(derived["b2b"] || [], 0, &(length(&1["inv"] || []) + &2)) +
        Enum.reduce(derived["b2cl"] || [], 0, &(length(&1["inv"] || []) + &2)) +
        Enum.reduce(derived["cdnr"] || [], 0, &(length(&1["nt"] || []) + &2)) +
        length(derived["cdnur"] || [])

    b2cs =
      Enum.count(
        active_invoices,
        &(Gstr1.filing_table(&1) in ["b2cs", "nil"] and Invoice.taxable_values_complete?(&1))
      )

    invoice_level + b2cs
  end

  defp draft_details(derived) do
    derived |> Gstr1.signed_details() |> Enum.map(& &1.detail)
  end

  defp totals_difference(draft, extracted) do
    Map.new(["taxable" | @tax_heads] ++ ["tax"], fn head ->
      key = String.to_existing_atom(head)
      {key, amount_difference(draft[key], extracted[key])}
    end)
    |> Map.put(:cess, nil)
  end

  defp amount_difference(left, right) when is_number(left) and is_number(right),
    do: Float.round(left - right, 2)

  defp amount_difference(_left, _right), do: nil

  defp empty_totals,
    do: %{taxable: 0.0, igst: 0.0, cgst: 0.0, sgst: 0.0, cess: nil, tax: 0.0}

  defp number(value) when is_integer(value), do: value * 1.0
  defp number(value) when is_float(value), do: value
  defp number(nil), do: 0.0
end
