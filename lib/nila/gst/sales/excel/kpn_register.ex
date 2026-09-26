defmodule Nila.Gst.Sales.Excel.KpnRegister do
  @moduledoc "Reads the ledger-column sales register supplied by KPN Chairs & Interiors."

  alias Nila.Gst.Extraction.Sales.Normalizer

  @sheet "Sales Register"
  @headings %{
    "A" => "Date",
    "B" => "Particulars",
    "C" => "Voucher Type",
    "D" => "Voucher No.",
    "F" => "GSTIN/UIN",
    "G" => "Gross Total",
    "I" => "Output C Gst@9%",
    "J" => "Output S Gst@9%",
    "K" => "Transport",
    "L" => "Round of",
    "N" => "Output Igst Tax @ 18%"
  }

  def matches?(%{sheets: sheets}) do
    Enum.any?(sheets, fn sheet ->
      sheet.name == @sheet and
        Enum.any?(sheet.rows, &headings?(&1.cells))
    end)
  end

  def parse(%{sheets: [%{name: @sheet, hidden?: false} = sheet]} = workbook, client, period) do
    with :ok <- check_period(period),
         :ok <- check_identity(sheet, client),
         :ok <- check_report_period(sheet, period),
         {:ok, header} <- find_header(sheet),
         {:ok, sales_columns} <- sales_columns(header),
         {:ok, invoices} <-
           invoices(
             sheet,
             header,
             sales_columns,
             client,
             period,
             Map.get(workbook, :date1904?, false)
           ) do
      if invoices == [],
        do: {:error, "Sales Register contains no invoices."},
        else: {:ok, %{"format" => "kpn_register", "rows" => [], "invoices" => invoices}}
    end
  catch
    {:report_error, message} -> {:error, message}
  end

  def parse(_, _, _), do: {:error, "Expected one visible Sales Register sheet."}

  defp check_period(period) do
    if Regex.match?(~r/\A\d{4}-(0[1-9]|1[0-2])\z/, period),
      do: :ok,
      else: {:error, "Select a GST month."}
  end

  defp check_identity(sheet, client) do
    printed =
      sheet.rows
      |> Enum.take(12)
      |> Enum.find_value(fn row ->
        case Regex.run(~r/\bGSTIN\/UIN\s*:\s*([0-9A-Z]{15})\b/i, row.cells["A"] || "") do
          [_, gstin] -> String.upcase(gstin)
          _ -> nil
        end
      end)

    cond do
      is_nil(printed) ->
        {:error, "Sales Register supplier GSTIN is missing."}

      printed != client.gstin ->
        {:error, "Sales Register supplier GSTIN does not match this client."}

      true ->
        :ok
    end
  end

  defp check_report_period(sheet, period) do
    dates =
      sheet.rows
      |> Enum.take(12)
      |> Enum.find_value(fn row ->
        case Regex.run(
               ~r/\A(\d{1,2}-[A-Za-z]{3}-\d{2,4})\s+to\s+(\d{1,2}-[A-Za-z]{3}-\d{2,4})\z/,
               row.cells["A"] || ""
             ) do
          [_, first, last] -> {Nila.Gst.Dates.parse_date(first), Nila.Gst.Dates.parse_date(last)}
          _ -> nil
        end
      end)

    case dates do
      {%Date{} = first, %Date{} = last} ->
        if Date.to_iso8601(first) |> String.starts_with?(period) and
             Date.to_iso8601(last) |> String.starts_with?(period),
           do: :ok,
           else: {:error, "Sales Register period does not match the selected GST month."}

      _ ->
        {:error, "Sales Register reporting period is missing or invalid."}
    end
  end

  defp find_header(sheet) do
    case Enum.find(Enum.take(sheet.rows, 25), &headings?(&1.cells)) do
      nil -> {:error, "Sales Register columns are missing or changed."}
      header -> {:ok, header}
    end
  end

  defp headings?(cells),
    do: Enum.all?(@headings, fn {column, heading} -> key(cells[column]) == key(heading) end)

  defp sales_columns(header) do
    with {:ok, local} <- sales_heading(header.cells["H"], "H"),
         {:ok, interstate} <- sales_heading(header.cells["M"], "M") do
      {:ok, %{local: local, interstate: interstate}}
    end
  end

  defp sales_heading(value, column) do
    case Regex.run(
           ~r/\A(?:GST|IGST)\s+SALES\s*@\s*(\d+(?:\.\d+)?)\s*%\s*\((\d{4,8})\)\z/i,
           value || ""
         ) do
      [_, rate, hsn] ->
        {parsed_rate, ""} = Float.parse(rate)
        {:ok, %{rate: parsed_rate, hsn: hsn}}

      _ ->
        {:error, "Sales Register #{column} heading lacks a GST rate or HSN code."}
    end
  end

  defp invoices(sheet, header, sales_columns, client, period, date1904?) do
    rows = Enum.filter(sheet.rows, &(&1.row > header.row))

    invoices =
      Enum.flat_map(rows, fn row ->
        if key(row.cells["B"]) == "grandtotal" do
          []
        else
          [invoice(sheet, row, sales_columns, client, period, date1904?)]
        end
      end)

    {:ok, invoices}
  end

  defp invoice(sheet, row, columns, client, period, date1904?) do
    c = row.cells
    local = amount(c["H"], sheet, row, "H")
    interstate = amount(c["M"], sheet, row, "M")
    cgst = amount(c["I"], sheet, row, "I")
    sgst = amount(c["J"], sheet, row, "J")
    igst = amount(c["N"], sheet, row, "N")
    buyer_gstin = string(c["F"])
    number = string(c["D"])
    date = date(c["A"], sheet, row, period, date1904?)

    if c["C"] != "Sales" or is_nil(number) or is_nil(string(c["B"])) or
         is_nil(amount(c["G"], sheet, row, "G")),
       do: fail(sheet, row, "Sales voucher number, buyer or gross total is missing.")

    {taxable, heading, taxes, pos} =
      cond do
        is_number(local) and is_nil(interstate) and is_number(cgst) and is_number(sgst) and
            is_nil(igst) ->
          pos = String.slice(client.gstin, 0, 2)

          if buyer_gstin && String.slice(buyer_gstin, 0, 2) != pos,
            do: fail(sheet, row, "Local tax conflicts with buyer GSTIN state.")

          {local, columns.local, %{"cgst_amount" => cgst, "sgst_amount" => sgst}, pos}

        is_number(interstate) and is_nil(local) and is_number(igst) and is_nil(cgst) and
            is_nil(sgst) ->
          if is_nil(buyer_gstin) or not Regex.match?(~r/\A\d{2}[0-9A-Z]{13}\z/, buyer_gstin),
            do: fail(sheet, row, "Interstate sale needs a buyer GSTIN to determine its state.")

          pos = String.slice(buyer_gstin, 0, 2)

          if pos == String.slice(client.gstin, 0, 2),
            do: fail(sheet, row, "IGST conflicts with buyer GSTIN state.")

          {interstate, columns.interstate, %{"igst_amount" => igst}, pos}

        true ->
          fail(
            sheet,
            row,
            "Taxable and tax columns do not identify one local or interstate sale."
          )
      end

    line =
      %{
        "description" => "#{heading.hsn} sales",
        "hsn_sac" => heading.hsn,
        "printed_taxable_value" => taxable,
        "cgst_rate" => if(is_number(local), do: heading.rate / 2),
        "sgst_rate" => if(is_number(local), do: heading.rate / 2),
        "igst_rate" => if(is_number(interstate), do: heading.rate)
      }
      |> Map.merge(taxes)

    data = %{
      "document_type" => "invoice",
      "document_status" => "active",
      "supply_type" => "taxable",
      "invoice_number" => number,
      "invoice_date" => date,
      "seller" => %{"gstin" => client.gstin},
      "buyer" => %{"name" => string(c["B"]), "gstin" => buyer_gstin},
      "recipient_registration" => if(buyer_gstin, do: "registered", else: "unregistered"),
      "place_of_supply" => pos,
      "printed_grand_total" => amount(c["G"], sheet, row, "G"),
      "printed_additional_charges" => amount(c["K"], sheet, row, "K"),
      "printed_rounding_adjustment" => amount(c["L"], sheet, row, "L"),
      "line_items" => [line]
    }

    Normalizer.normalize(%{"data" => data})
    |> Map.merge(%{
      "id" => "kpn_#{row.row}",
      "source_sheet" => sheet.name,
      "source_rows" => [row.row],
      "source_pages" => [],
      "source_cells" => serializable_cells(c),
      "source_headers" => header_cells(sheet),
      "source_transport_amount" => amount(c["K"], sheet, row, "K"),
      "source_rounding_amount" => amount(c["L"], sheet, row, "L"),
      "place_of_supply_basis" =>
        if(is_number(local), do: "CGST/SGST; seller state", else: "IGST; buyer GSTIN state"),
      "return_report_section" => "KPN"
    })
  end

  defp header_cells(sheet),
    do:
      sheet.rows |> Enum.find(&headings?(&1.cells)) |> Map.fetch!(:cells) |> serializable_cells()

  defp serializable_cells(cells),
    do:
      Map.new(cells, fn {column, value} ->
        {column, if(is_atom(value), do: to_string(value), else: value)}
      end)

  defp date(raw, sheet, row, period, date1904?) do
    date_text = raw |> string() |> to_string() |> String.split("T", parts: 2) |> hd()

    parsed =
      case Integer.parse(date_text) do
        {serial, ""} when serial > 0 and serial < 100_000 ->
          base = if(date1904?, do: ~D[1904-01-01], else: ~D[1899-12-30])
          Date.add(base, serial)

        _ ->
          Nila.Gst.Dates.parse_date(date_text)
      end

    case parsed do
      %Date{} = date ->
        iso = Date.to_iso8601(date)

        if String.starts_with?(iso, period),
          do: iso,
          else: fail(sheet, row, "Invoice is outside the selected GST month.")

      _ ->
        fail(sheet, row, "Invoice date is missing or invalid.")
    end
  end

  defp amount(nil, _, _, _), do: nil
  defp amount("", _, _, _), do: nil

  defp amount(value, sheet, row, column) do
    if value in [:formula, :invalid_cell],
      do: fail(sheet, row, "#{column} contains a formula or cell error.")

    case Float.parse(String.replace(to_string(value), ",", "")) do
      {number, ""} when abs(number) < 1.0e12 -> number
      _ -> fail(sheet, row, "#{column} is not a valid amount.")
    end
  end

  defp key(nil), do: ""

  defp key(value),
    do: value |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  defp string(value) when value in [nil, "", :formula, :invalid_cell], do: nil
  defp string(value), do: value |> to_string() |> String.trim()

  defp fail(sheet, row, message),
    do: throw({:report_error, "#{sheet.name}, row #{row.row}: #{message}"})
end
