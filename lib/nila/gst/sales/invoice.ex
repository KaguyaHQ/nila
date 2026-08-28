defmodule Nila.Gst.Sales.Invoice do
  @moduledoc """
  Canonical operations over a normalized sales invoice.

  This module owns invoice identity, editable field paths, extracted totals,
  and line-amount materialization. Filing and destination modules consume these
  facts; they do not define what a sales invoice field means.
  """

  alias Nila.Gst.Extraction.LineAmounts
  alias Nila.Gst.Money

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

  @doc "Writes a scalar invoice field, including `line_items[index].field` paths."
  def put_field(invoice, field_path, value) do
    case parse_field_path(field_path) do
      {:line, index, line_field} ->
        Map.update!(invoice, "line_items", fn lines ->
          List.update_at(lines, index, &Map.put(&1, line_field, value))
        end)

      {:invoice, field} ->
        Map.put(invoice, field, value)
    end
  end

  @doc "Coerces correction text for numeric fields accepted by the review UI."
  def coerce_correction(field_path, text) do
    cond do
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
    Map.update(invoice, "line_items", [], fn lines -> Enum.map(lines, &resolve_line_amount/1) end)
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
