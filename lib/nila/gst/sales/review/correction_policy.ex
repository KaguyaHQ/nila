defmodule Nila.Gst.Sales.Review.CorrectionPolicy do
  @moduledoc """
  Flags invoice fields from extraction confidence and validation findings, and
  identifies which review corrections are allowed. Invoice owns field meaning
  and mutation; this module owns eligibility and source targeting.

  `apply_corrections/3` also reports unflagged corrections for evaluation.
  Production Workings filters those out before applying them.
  """

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.Invoice

  @confidence_threshold 0.90
  @correctable_invoice_fields ~w(
    document_type document_status supply_type tax_payment reverse_charge recipient_registration place_of_supply original_sale_category
    invoice_number invoice_date seller_name seller_gstin buyer_name buyer_gstin
    printed_total_taxable printed_total_tax printed_grand_total
  )
  @correctable_line_fields Invoice.correctable_line_fields()
  @doc "Returns the flagged scalar fields that may be corrected for a source invoice."
  def correctable_fields(flagged, pristine_source_id) do
    flagged
    |> Enum.filter(fn {source_id, field} ->
      source_id == pristine_source_id and correctable_field?(field)
    end)
    |> Enum.map(fn {_source_id, field} -> field end)
    |> Enum.sort()
  end

  @doc "Whether a path names a business field the review flow may edit."
  def correctable_field?(field) when field in @correctable_invoice_fields, do: true

  def correctable_field?(field) when is_binary(field) do
    case Invoice.parse_field_path(field) do
      {:line, _index, line_field} -> line_field in @correctable_line_fields
      {:invoice, _field} -> false
    end
  end

  def correctable_field?(_field), do: false

  @doc "Whether a flagged correction is authorized for a source invoice and field path."
  def correction_allowed?(flagged, source_id, field) do
    correctable_field?(field) and
      (MapSet.member?(flagged, {source_id, field}) or
         Enum.any?(flagged, fn
           {^source_id, flagged_field}
           when is_binary(flagged_field) and is_binary(field) ->
             String.starts_with?(field, flagged_field <> "[") or
               String.starts_with?(field, flagged_field <> ".")

           _ ->
             false
         end))
  end

  def flagged_fields(invoices, issues) do
    low_conf =
      invoices
      |> Enum.flat_map(fn invoice ->
        confidence = invoice["confidence"] || %{}
        source_id = Invoice.source_id(invoice)

        confidence
        |> flatten_confidence()
        |> Enum.filter(fn {_field, value} ->
          is_number(value) and value < @confidence_threshold
        end)
        |> Enum.map(fn {field, _value} -> %{"source_id" => source_id, "field" => field} end)
      end)

    validation =
      issues
      |> Enum.reject(&(Issues.level(&1) == "info"))
      |> Enum.flat_map(fn issue ->
        # `source_ids` means the named fields apply equally to every member of
        # one source group; today only duplicate-number issues carry it.
        source_ids = issue["source_ids"] || [issue["source_id"] || issue["invoice"]]

        for source_id <- source_ids,
            field <- issue["fields"] || [],
            do: %{"source_id" => source_id, "field" => field}
      end)

    MapSet.new(low_conf ++ validation, &flag_key/1)
  end

  @doc """
  Applies review corrections to normalized invoices.

  Corrections target a source ID, or an unambiguous invoice number. This function
  applies targeted edits and separately reports corrections to unflagged fields
  as silent errors for evaluation. Production callers must filter eligibility
  with `correction_allowed?/3` before calling it.

  Returns `{final_invoices, flagged_corrections, silent_errors, flagged}`.
  """
  def apply_corrections(invoices, nil, flagged), do: {invoices, [], [], flagged}

  def apply_corrections(invoices, corrections, flagged) when is_list(corrections) do
    Enum.reduce(corrections, {invoices, [], [], flagged}, fn correction,
                                                             {acc, flagged_ok, silent, flags} ->
      target = correction_target(acc, correction)

      updated =
        Enum.map(acc, fn invoice ->
          if target && Invoice.source_id(invoice) == target do
            Invoice.apply_correction(invoice, correction["field"], correction["value"])
          else
            invoice
          end
        end)

      if target && correction_allowed?(flags, target, correction["field"]) do
        {updated, [correction | flagged_ok], silent, flags}
      else
        {updated, flagged_ok, [correction | silent], flags}
      end
    end)
  end

  defp correction_target(invoices, %{"source_id" => source_id}) when is_binary(source_id) do
    if Enum.any?(invoices, &(Invoice.source_id(&1) == source_id)), do: source_id
  end

  defp correction_target(invoices, correction) do
    case correction["invoice"] || correction["inum"] do
      invoice_number when is_binary(invoice_number) ->
        matches = Enum.filter(invoices, &(&1["invoice_number"] == invoice_number))
        if length(matches) == 1, do: matches |> hd() |> Invoice.source_id()

      _missing ->
        nil
    end
  end

  defp flatten_confidence(map, prefix \\ nil) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      field = if prefix, do: "#{prefix}.#{key}", else: key

      cond do
        is_map(value) and is_number(value["confidence"]) -> [{field, value["confidence"]}]
        is_map(value) -> flatten_confidence(value, field)
        is_list(value) -> flatten_list_confidence(value, field)
        is_number(value) -> [{field, value}]
        true -> []
      end
    end)
  end

  defp flatten_list_confidence(values, prefix) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      if is_map(value), do: flatten_confidence(value, "#{prefix}[#{index}]"), else: []
    end)
  end

  defp flag_key(%{"source_id" => source_id, "field" => field}), do: {source_id, field}
  defp flag_key(%{"invoice" => invoice, "field" => field}), do: {invoice, field}
  defp flag_key(%{"inum" => invoice, "field" => field}), do: {invoice, field}
end
