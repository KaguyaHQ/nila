defmodule Nila.Gst.Sales.Invoice do
  @moduledoc """
  Canonical operations over a normalized sales invoice.

  This module owns invoice identity, editable field paths, extracted totals,
  and line-amount materialization. Filing and destination modules consume these
  facts; they do not define what a sales invoice field means.
  """

  alias Nila.Gst.Extraction.LineAmounts
  alias Nila.Gst.Money
  alias Nila.Gst.StateCodes

  @correctable_line_fields ~w(
    item_name description hsn_sac quantity uom printed_unit_price printed_line_amount
    printed_line_total printed_taxable_value line_amount_tax_inclusion taxable_value
    cgst_rate cgst_amount sgst_rate sgst_amount igst_rate igst_amount
  )

  @doc "Line fields that an accountant may correct in a source invoice."
  def correctable_line_fields, do: @correctable_line_fields

  @doc "The canonical source-document classification used by filing and accounting."
  def document_type(invoice), do: invoice["document_type"] || "invoice"

  @doc "Recipient registration with backward-compatible inference for stored registered invoices."
  def recipient_registration(invoice) do
    invoice["recipient_registration"] ||
      if(is_nil(blank_to_nil(invoice["buyer_gstin"])), do: "unknown", else: "registered")
  end

  @doc "The source document's number, retained in the legacy invoice-number storage key."
  def document_number(invoice), do: invoice["invoice_number"]

  @doc "The source document's date, retained in the legacy invoice-date storage key."
  def document_date(invoice), do: invoice["invoice_date"]

  @doc "The direction this source document contributes to outward liability."
  def document_effect(invoice) do
    if document_type(invoice) == "credit_note", do: -1, else: 1
  end

  def document_status(invoice), do: invoice["document_status"] || "active"

  def supply_type(invoice) do
    invoice["supply_type"] ||
      if(get_in(invoice, ["document", "export"]), do: "export", else: "taxable")
  end

  def zero_rated?(invoice) do
    supply = invoice["supply_type"] || if((invoice["document"] || %{})["export"], do: "export")
    supply in ~w(export sez)
  end

  def without_payment?(invoice),
    do: zero_rated?(invoice) and invoice["tax_payment"] == "without_payment"

  def reverse_charge?(invoice) do
    case invoice["reverse_charge"] do
      nil -> (invoice["document"] || %{})["reverse_charge"] == true
      value -> value == true
    end
  end

  def tax_excluded_from_total?(invoice),
    do: reverse_charge?(invoice) or without_payment?(invoice)

  def special_supply_conflict?(invoice) do
    document = invoice["document"] || %{}
    supply = invoice["supply_type"] || if(document["export"], do: "export", else: "taxable")
    has_gstin? = invoice["buyer_gstin"] not in [nil, ""]
    registration = invoice["recipient_registration"] || if(has_gstin?, do: "registered")

    (reverse_charge?(invoice) and (supply != "taxable" or registration != "registered")) or
      (supply == "sez" and (registration != "registered" or not has_gstin?)) or
      (supply == "export" and has_gstin?) or
      (supply not in ~w(export sez) and invoice["tax_payment"] in ~w(with_payment without_payment)) or
      (document["export"] == true and supply not in ~w(export sez)) or
      invoice["reverse_charge"] not in [nil, true, false]
  end

  @numeric_correction_field ~r/^(printed_total_taxable|printed_total_tax|printed_grand_total)$|\.(taxable_value|printed_(unit_price|line_amount|line_total|taxable_value)|quantity|[csi]gst_(rate|amount))$/

  @doc "Stable source identity when present, otherwise the legacy invoice-number identity."
  def source_id(invoice), do: invoice["id"] || invoice["invoice_number"]

  @doc "Parses a top-level or `line_items[index].field` invoice field path."
  def parse_field_path(field_path) do
    case Regex.run(~r/^line_items\[(\d+)\]\.(.+)$/, field_path || "") do
      [_, index, line_field] -> {:line, String.to_integer(index), line_field}
      _not_a_line_path -> {:invoice, field_path}
    end
  end

  @doc "Reads a scalar invoice field, including `line_items[index].field` paths."
  def field_value(invoice, field_path) do
    case parse_field_path(field_path) do
      {:line, index, line_field} ->
        line = Enum.at(invoice["line_items"] || [], index) || %{}
        line[line_field]

      {:invoice, field} ->
        invoice[field]
    end
  end

  @doc "Applies a review correction and updates the facts and evidence affected by it."
  def apply_correction(invoice, field, value) do
    case parse_field_path(field) do
      {:line, index, line_field} ->
        invoice
        |> update_in(["line_items", Access.at(index)], fn line ->
          line = line || %{}

          line =
            if line_field == "line_amount_tax_inclusion" do
              line
              |> Map.put_new(
                "line_amount_tax_inclusion_candidate",
                line["line_amount_tax_inclusion"] || "unknown"
              )
              |> Map.put("line_amount_tax_inclusion_basis", "corrected")
            else
              line
            end

          line
          |> Map.put(line_field, value)
          |> update_corrected_taxable(line_field)
        end)
        |> clear_verification_failure(field)

      {:invoice, "buyer_gstin"} ->
        corrected =
          case blank_to_nil(value) do
            nil ->
              Map.put(invoice, "buyer_gstin", nil)

            gstin ->
              invoice
              |> Map.put("buyer_gstin", gstin)
              |> Map.put("recipient_registration", "registered")
          end

        clear_verification_failure(corrected, "buyer_gstin")

      {:invoice, "place_of_supply"} ->
        Map.put(invoice, "place_of_supply", normalize_place_of_supply(value))

      {:invoice, "recipient_registration"} ->
        Map.put(invoice, "recipient_registration", normalize_recipient_registration(value))

      {:invoice, "document_status"} ->
        Map.put(invoice, "document_status", normalize_document_status(value))

      {:invoice, "supply_type"} ->
        supply = normalize_supply_type(value, invoice["document"] || %{})

        invoice
        |> Map.put("supply_type", supply)
        |> Map.update("document", %{"export" => supply in ~w(export sez)}, fn document ->
          Map.put(document || %{}, "export", supply in ~w(export sez))
        end)
        |> resolve_line_amounts()

      {:invoice, field} ->
        invoice
        |> Map.put(field, value)
        |> clear_verification_failure(field)
    end
  end

  defp clear_verification_failure(%{"verification" => verification} = invoice, field)
       when is_map(verification) do
    update_in(invoice, ["verification", "failed_checks"], fn checks ->
      checks
      |> List.wrap()
      |> Enum.reject(&(verification_field(&1) == field))
    end)
  end

  defp clear_verification_failure(invoice, _field), do: invoice

  defp update_corrected_taxable(line, "taxable_value"),
    do: Map.put(line, "taxable_value_basis", "corrected")

  defp update_corrected_taxable(line, field)
       when field in ~w(printed_line_amount printed_line_total printed_taxable_value line_amount_tax_inclusion cgst_rate cgst_amount sgst_rate sgst_amount igst_rate igst_amount) do
    resolve_line_amount(line)
  end

  defp update_corrected_taxable(line, _field), do: line

  defp normalize_recipient_registration(status)
       when status in ~w(registered unregistered unknown), do: status

  defp normalize_recipient_registration(_status), do: "unknown"

  defp normalize_place_of_supply(nil), do: nil

  defp normalize_place_of_supply(value) do
    value = value |> to_string() |> String.trim()

    StateCodes.normalize_code(value) ||
      Enum.find_value(StateCodes.all(), fn name ->
        if String.downcase(name) == String.downcase(value), do: StateCodes.code_for(name)
      end) || blank_to_nil(value)
  end

  defp normalize_document_status(status) when status in ~w(active cancelled amendment unknown),
    do: status

  defp normalize_document_status(nil), do: "active"
  defp normalize_document_status(_status), do: "unknown"

  defp normalize_supply_type(status, _document)
       when status in ~w(taxable nil_rated exempt non_gst export sez unknown),
       do: status

  defp normalize_supply_type(nil, %{"export" => true}), do: "export"
  defp normalize_supply_type(nil, _document), do: "taxable"
  defp normalize_supply_type(_status, _document), do: "unknown"

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  @doc "Coerces correction text for numeric fields accepted by the review UI."
  def coerce_correction(field_path, text) do
    cond do
      field_path == "reverse_charge" and text in ["true", "false"] ->
        text == "true"

      Regex.match?(@numeric_correction_field, field_path) and String.trim(text) == "" ->
        nil

      Regex.match?(@numeric_correction_field, field_path) ->
        Money.rupee_number(text) || text

      true ->
        text
    end
  end

  @doc "Sums extracted taxable and tax amounts without deriving or rounding them."
  def extracted_totals(invoice) do
    lines = List.wrap(invoice["line_items"])

    taxable =
      if Enum.all?(lines, &is_number(&1["taxable_value"])),
        do: Enum.sum(Enum.map(lines, & &1["taxable_value"])),
        else: nil

    tax =
      Enum.reduce(lines, 0, fn line, total ->
        total + extracted_number(line["cgst_amount"]) + extracted_number(line["sgst_amount"]) +
          extracted_number(line["igst_amount"])
      end)

    %{taxable: taxable, tax: tax}
  end

  @doc "Sums extracted invoice money as canonical integer paise."
  def extracted_totals_paise(invoice) do
    lines = List.wrap(invoice["line_items"])

    taxable = sum_required_paise(lines, "taxable_value")

    tax =
      Enum.reduce(lines, 0, fn line, total ->
        total + optional_paise(line["cgst_amount"]) + optional_paise(line["sgst_amount"]) +
          optional_paise(line["igst_amount"])
      end)

    %{taxable_paise: taxable, tax_paise: tax}
  end

  @doc "Re-resolves normalized line amounts from their preserved printed evidence."
  def resolve_line_amounts(invoice) do
    Map.update(invoice, "line_items", [], fn lines ->
      Enum.map(lines, fn line ->
        line = resolve_line_amount(line)

        no_tax? =
          Enum.all?(
            ~w(cgst_rate sgst_rate igst_rate cgst_amount sgst_amount igst_amount),
            &(extracted_number(line[&1]) == 0)
          )

        if invoice["supply_type"] in ~w(nil_rated exempt non_gst) and no_tax? and
             is_nil(line["taxable_value"]) and is_number(line["printed_line_amount"]) do
          line
          |> Map.put("taxable_value", line["printed_line_amount"])
          |> Map.put("taxable_value_basis", "non_taxable_line_amount")
        else
          line
        end
      end)
    end)
  end

  @doc "Re-resolves one normalized line from its preserved printed evidence."
  def resolve_line_amount(line) do
    amounts = LineAmounts.normalize(line)

    Map.merge(line, %{
      "printed_unit_price" => amounts.printed_unit_price,
      "printed_line_amount" => amounts.printed_line_amount,
      "printed_line_total" => amounts.printed_line_total,
      "printed_taxable_value" => amounts.printed_taxable_value,
      "line_amount_tax_inclusion_candidate" => amounts.line_amount_tax_inclusion_candidate,
      "line_amount_tax_inclusion" => amounts.line_amount_tax_inclusion,
      "line_amount_tax_inclusion_basis" => amounts.line_amount_tax_inclusion_basis,
      "line_amount_tax_inclusion_evidence" => amounts.line_amount_tax_inclusion_evidence,
      "line_amount_tax_inclusion_disagreement" => amounts.line_amount_tax_inclusion_disagreement,
      "taxable_value" => amounts.taxable_value,
      "taxable_value_basis" => amounts.taxable_value_basis
    })
  end

  @doc "Whether every line has a known taxable value, including a genuine zero."
  def taxable_values_complete?(invoice) do
    Enum.all?(List.wrap(invoice["line_items"]), &is_number(&1["taxable_value"]))
  end

  @doc "Maps extraction verification paths onto normalized invoice fields."
  def verification_field(%{"field" => "seller.gstin"}), do: "seller_gstin"
  def verification_field(%{"field" => "buyer.gstin"}), do: "buyer_gstin"
  def verification_field(%{"field" => "supplier.gstin"}), do: "seller_gstin"
  def verification_field(%{"field" => "bill_to.gstin"}), do: "buyer_gstin"
  def verification_field(%{"field" => field}) when is_binary(field), do: field
  def verification_field(_check), do: nil

  defp extracted_number(value) when is_number(value), do: value
  defp extracted_number(_value), do: 0

  defp sum_required_paise(lines, field) do
    Enum.reduce_while(lines, 0, fn line, total ->
      case Money.paise_or_error(line[field]) do
        {:ok, paise} -> {:cont, total + paise}
        _missing_or_unreadable -> {:halt, nil}
      end
    end)
  end

  defp optional_paise(nil), do: 0
  defp optional_paise(value), do: Money.paise(value)
end
