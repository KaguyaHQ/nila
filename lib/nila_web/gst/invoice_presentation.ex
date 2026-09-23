defmodule NilaWeb.Gst.InvoicePresentation do
  @moduledoc "Source invoice amounts and labels for React review."
  alias Nila.Gst.Sales.Invoice.Validation, as: InvoiceValidation
  alias Nila.Gst.Money

  def place_of_supply_label(nil), do: "Not determined"
  def place_of_supply_label(""), do: "Not determined"

  def place_of_supply_label(code) do
    case Nila.Gst.StateCodes.name_for(code) do
      nil -> code
      name -> "#{name} (#{code})"
    end
  end

  def invoice_total_rows(invoice) do
    checks = InvoiceValidation.checks(invoice)
    totals = Nila.Gst.Sales.Invoice.Validation.comparison_totals(invoice)
    printed_totals = Nila.Gst.Sales.Review.Values.printed(invoice)

    for {label, field, code, calculated} <- [
          {"Taxable", :taxable, "printed_taxable_mismatch", totals.taxable},
          {"GST", :tax, "printed_tax_mismatch", totals.tax},
          {"Grand total", :total, "grand_total_mismatch", totals.total}
        ] do
      check = Enum.find(checks, &(&1["code"] == code))
      printed = printed_totals[field]
      mismatch? = check != nil && check["passed"] == false

      %{
        label: label,
        field: field,
        matches?: check != nil && check["passed"] == true,
        calculated: calculated,
        printed: printed,
        mismatch?: mismatch?,
        difference:
          if(mismatch?, do: Money.rupees(abs(Money.paise(printed) - Money.paise(calculated))))
      }
    end
  end

  def rupees(value) do
    case Money.paise_or_error(value) do
      {:ok, paise} -> Nila.Formatters.format_money_with_paise(paise)
      _missing_or_unreadable -> "—"
    end
  end

  def working_number(value) when is_integer(value), do: Integer.to_string(value)

  def working_number(value) when is_float(value) do
    if value == trunc(value), do: Integer.to_string(trunc(value)), else: Float.to_string(value)
  end

  def working_number(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: "—", else: value
  end

  def working_number(_value), do: "—"
end
