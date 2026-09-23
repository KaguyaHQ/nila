defmodule NilaWeb.Gst.InvoiceCheckPresentation do
  @moduledoc "Arithmetic check results for the invoice review API."
  alias Nila.Gst.Sales.Invoice.Validation

  @totals [
    {"printed_taxable_mismatch", "Taxable total"},
    {"printed_tax_mismatch", "GST total"},
    {"grand_total_mismatch", "Invoice total"}
  ]

  def results(invoice) do
    checks =
      Validation.checks(invoice)
      |> Enum.reject(fn check ->
        check["code"] == "cgst_sgst_unequal" &&
          check["operands"]["cgst"] == 0 && check["operands"]["sgst"] == 0
      end)

    totals =
      Enum.map(@totals, fn {code, label} ->
        case Enum.find(checks, &(&1["code"] == code)) do
          nil ->
            %{
              label: label,
              title: "#{label} — not compared",
              secondary: nil,
              difference: nil,
              detail: unavailable_total(invoice, code, label),
              status: :unavailable
            }

          check ->
            row(
              check,
              label,
              "#{calculated_label(code)} #{money(check["operands"]["derived"])} · #{printed_label(code)} #{money(check["operands"]["printed"])}",
              check["operands"]["derived"],
              check["operands"]["printed"]
            )
        end
      end)

    lines =
      Enum.flat_map(checks, fn check ->
        ops = check["operands"]

        case check["code"] do
          "line_arithmetic" ->
            [
              row(
                check,
                "Line #{check["line"]} tax",
                "#{money(ops["taxable"])} × #{ops["rate"]}% = #{money(ops["expected"])}",
                ops["expected"],
                ops["actual"],
                "Captured tax #{money(ops["actual"])}"
              )
            ]

          "cgst_sgst_unequal" ->
            [
              row(
                check,
                "Line #{check["line"]}: CGST and SGST",
                "CGST #{money(ops["cgst"])} · SGST #{money(ops["sgst"])}",
                ops["cgst"],
                ops["sgst"]
              )
            ]

          _ ->
            []
        end
      end)

    totals ++ lines
  end

  defp unavailable_total(invoice, code, _label) do
    field =
      case code do
        "printed_taxable_mismatch" -> :taxable
        "printed_tax_mismatch" -> :tax
        "grand_total_mismatch" -> :total
      end

    printed = Nila.Gst.Sales.Review.Values.printed(invoice)[field]
    calculated = Validation.comparison_totals(invoice)[field]

    reason =
      cond do
        is_nil(printed) and is_nil(calculated) ->
          "the printed amount was not read and the line amounts are incomplete"

        is_nil(printed) ->
          "the printed amount was not read"

        true ->
          "the line amounts are incomplete, so Nila could not calculate a total"
      end

    "#{reason |> String.capitalize()}."
  end

  defp calculated_label("printed_taxable_mismatch"), do: "Sum of lines"
  defp calculated_label("printed_tax_mismatch"), do: "Sum of line taxes"
  defp calculated_label("grand_total_mismatch"), do: "Calculated payable"
  defp printed_label("printed_tax_mismatch"), do: "Printed GST"
  defp printed_label(_), do: "Printed total"

  defp row(check, label, detail, left, right, secondary \\ nil) do
    delta =
      Decimal.sub(Decimal.new(to_string(left)), Decimal.new(to_string(right))) |> Decimal.abs()

    equal? = Decimal.equal?(delta, 0)
    plural? = check["code"] == "cgst_sgst_unequal"

    outcome =
      cond do
        not check["passed"] -> if plural?, do: "do not match", else: "does not match"
        not equal? -> "within tolerance"
        plural? -> "match"
        true -> "matches"
      end

    difference =
      if not equal? do
        amount =
          if Decimal.compare(delta, Decimal.new("0.01")) == :lt,
            do: "Less than ₹0.01",
            else: money(Decimal.to_float(delta))

        "#{amount} difference · Allowed ₹0.50"
      end

    %{
      label: label,
      title: "#{label} #{outcome}",
      detail: detail,
      secondary: secondary,
      difference: difference,
      status: if(check["passed"], do: :passed, else: :failed)
    }
  end

  defp money(value), do: Nila.Formatters.format_money_with_paise(Nila.Gst.Money.paise(value))
end
