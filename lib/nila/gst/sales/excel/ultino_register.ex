defmodule Nila.Gst.Sales.Excel.UltinoRegister do
  @moduledoc "Reads ULTINO's printed GST sales register as sourced B2B invoices."

  @columns %{
    "buyer_gstin" => "H",
    "buyer_name" => "E",
    "number" => "B",
    "date" => "D",
    "value" => "AC",
    "rate" => "L",
    "txval" => "J",
    "camt" => "O",
    "samt" => "S",
    "iamt" => "W"
  }

  def matches?(%{sheets: [%{name: "Sheet1", rows: rows}]}) do
    title = Enum.find(rows, &(&1.row == 1))
    period = Enum.find(rows, &(&1.row == 3))
    headings = Enum.find(rows, &(&1.row == 6))

    title && period && headings &&
      String.contains?(text(title.cells["A"]), "ULTINO") &&
      String.contains?(text(period.cells["A"]), "GST Sales Details") &&
      Enum.all?(
        %{"B" => "Inv.No", "D" => "Inv.Date", "H" => "Party GSTIN No", "J" => "Taxable Value"},
        fn {col, expected} ->
          text(headings.cells[col]) == expected
        end
      )
  end

  def matches?(_), do: false

  def parse(workbook, client, period) do
    with true <- matches?(workbook),
         false <- Enum.any?(workbook.sheets, & &1.hidden?),
         :ok <- valid_period(period),
         :ok <- report_period(hd(workbook.sheets), period),
         {:ok, rows} <- read_rows(hd(workbook.sheets), client, period) do
      {:ok, %{"format" => "ultino_register", "rows" => rows}}
    else
      false -> {:error, "This is not the expected ULTINO sales register."}
      true -> {:error, "Hidden report sheets are not supported."}
      error -> error
    end
  catch
    {:report_error, message} -> {:error, message}
  end

  defp valid_period(period) do
    if Regex.match?(~r/\A\d{4}-(0[1-9]|1[0-2])\z/, period),
      do: :ok,
      else: {:error, "Select a GST month."}
  end

  defp report_period(sheet, period) do
    row = Enum.find(sheet.rows, &(&1.row == 3))
    label = text(row.cells["A"])
    {:ok, first} = Date.from_iso8601(period <> "-01")
    last = Date.end_of_month(first)
    printed_first = Calendar.strftime(first, "%d-%b-%Y")
    printed_last = Calendar.strftime(last, "%d-%b-%Y")

    if String.contains?(label, "From #{printed_first} To #{printed_last}"),
      do: :ok,
      else: {:error, "Report period does not match the selected GST month."}
  end

  defp read_rows(sheet, client, period) do
    header = Enum.find(sheet.rows, &(&1.row == 6))

    rows =
      sheet.rows
      |> Enum.filter(&(&1.row > 6))
      |> Enum.reject(&(is_nil(&1.cells["B"]) and is_nil(&1.cells["D"])))
      |> Enum.map(&read_invoice(sheet, header, &1, client, period))

    if rows == [],
      do: {:error, "This report contains no invoices."},
      else: {:ok, rows}
  end

  defp read_invoice(sheet, header, row, client, period) do
    c = row.cells
    number = invoice_number(c["B"], sheet, row)
    date = invoice_date(c["D"], sheet, row, period)
    buyer_gstin = text(c["H"])

    if !Regex.match?(~r/\A\d{2}[A-Z0-9]{13}\z/, buyer_gstin),
      do: fail(sheet, row, "Recipient GSTIN is missing or invalid.")

    taxable = required_amount(c["J"], sheet, row, "J")
    value = required_amount(c["AC"], sheet, row, "AC")
    cgst_rate = amount(c["L"], sheet, row, "L") || 0.0
    sgst_rate = amount(c["P"], sheet, row, "P") || 0.0
    igst_rate = amount(c["U"], sheet, row, "U") || 0.0
    cgst = amount(c["O"], sheet, row, "O") || 0.0
    sgst = amount(c["S"], sheet, row, "S") || 0.0
    igst = amount(c["W"], sheet, row, "W") || 0.0
    seller_state = String.slice(client.gstin, 0, 2)
    recipient_state = String.slice(buyer_gstin, 0, 2)

    cond do
      cgst_rate + sgst_rate + igst_rate <= 0 ->
        fail(sheet, row, "GST rate is missing.")

      recipient_state == seller_state and (igst != 0 or igst_rate != 0) ->
        fail(sheet, row, "IGST conflicts with the recipient's state.")

      recipient_state != seller_state and
          (cgst != 0 or sgst != 0 or cgst_rate != 0 or sgst_rate != 0) ->
        fail(sheet, row, "CGST/SGST conflicts with the recipient's state.")

      recipient_state == seller_state and (cgst_rate == 0 or sgst_rate == 0) ->
        fail(sheet, row, "Local tax pattern is incomplete.")

      recipient_state != seller_state and igst_rate == 0 ->
        fail(sheet, row, "Interstate tax pattern is incomplete.")

      true ->
        :ok
    end

    values = %{
      "seller_gstin" => client.gstin,
      "period" => String.slice(period, 5, 2) <> String.slice(period, 0, 4),
      "buyer_gstin" => buyer_gstin,
      "buyer_name" => text(c["E"]),
      "number" => number,
      "date" => date,
      "value" => value,
      "pos" => recipient_state,
      "pos_basis" => "recipient_gstin_tax_pattern",
      "reverse_charge" => nil,
      "rate" => cgst_rate + sgst_rate + igst_rate,
      "txval" => taxable,
      "iamt" => igst,
      "camt" => cgst,
      "samt" => sgst,
      "csamt" => 0.0
    }

    %{
      "sheet" => sheet.name,
      "return_sheet" => "B2B",
      "section" => "b2b",
      "row" => row.row,
      "values" => values,
      "headers" => header.cells,
      "columns" => @columns,
      "cells" =>
        Map.new(c, fn {col, value} ->
          {col, if(is_atom(value), do: to_string(value), else: value)}
        end)
    }
  end

  defp invoice_number(value, sheet, row) do
    case text(value) do
      "" -> fail(sheet, row, "Invoice number is missing.")
      number -> String.replace(number, ~r/\.0\z/, "")
    end
  end

  defp invoice_date(value, sheet, row, period) do
    raw = text(value)
    date = Nila.Gst.Dates.parse_date(String.slice(raw, 0, 10))

    cond do
      is_nil(date) ->
        fail(sheet, row, "Invoice date is invalid.")

      !String.starts_with?(Date.to_iso8601(date), period) ->
        fail(sheet, row, "Invoice is outside the selected GST month.")

      true ->
        Date.to_iso8601(date)
    end
  end

  defp required_amount(value, sheet, row, col) do
    case amount(value, sheet, row, col) do
      nil -> fail(sheet, row, "#{col} is missing.")
      number -> number
    end
  end

  defp amount(value, _sheet, _row, _col) when value in [nil, ""], do: nil

  defp amount(value, sheet, row, col) do
    if value in [:formula, :invalid_cell],
      do: fail(sheet, row, "#{col} contains a formula or cell error.")

    case Float.parse(String.replace(text(value), ",", "")) do
      {number, ""} when abs(number) < 1.0e12 -> number
      _ -> fail(sheet, row, "#{col} is not a valid amount.")
    end
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)

  defp text(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 8])

  defp text(_), do: ""

  defp fail(sheet, row, message),
    do: throw({:report_error, "#{sheet.name}, row #{row.row}: #{message}"})
end
