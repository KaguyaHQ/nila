defmodule Nila.Gst.Purchase.Excel do
  @moduledoc "Map a purchase worksheet to invoice facts, with explicit row exclusions and source evidence."
  alias Nila.Gst.Sales.Excel.Workbook
  alias Nila.Gst.Purchase.Books
  alias Nila.Gst.{Dates, Money}

  @fields [
    {"invoice_number", "Invoice number",
     ~w(invoicenumber invoiceno invno billno billnumber voucherno)},
    {"invoice_date", "Invoice date", ~w(invoicedate billdate date voucherdate)},
    {"vendor_name", "Supplier",
     ~w(supplier suppliername vendor vendorname seller sellername party partyname)},
    {"vendor_gstin", "Supplier GSTIN", ~w(suppliergstin vendorgstin sellergstin gstin gstinuin)},
    {"hsn_sac", "HSN/SAC", ~w(hsn hsncode hsnsac sac saccode)},
    {"description", "Item description",
     ~w(description item itemname itemdescription particulars)},
    {"taxable_value", "Taxable value per row",
     ~w(taxablevalue taxableamount taxable netamount assessablevalue)},
    {"gst_rate", "GST rate (%)", ~w(gstrate taxrate gstpercent)},
    {"cgst_amount", "CGST amount per row", ~w(cgst cgstamount centraltax)},
    {"sgst_amount", "SGST amount per row", ~w(sgst sgstamount statetax utgst)},
    {"igst_amount", "IGST amount per row", ~w(igst igstamount integratedtax)},
    {"invoice_total", "Invoice total (once or repeated)",
     ~w(invoicetotal invoicevalue grandtotal billamount)},
    {"document_type", "Document type", ~w(documenttype vouchertype)},
    {"supply_type", "Supply type", ~w(supplytype purchasetype)},
    {"reverse_charge", "Reverse charge", ~w(reversecharge rcm)}
  ]
  @required ~w(invoice_number invoice_date vendor_gstin taxable_value)
  @amounts ~w(taxable_value cgst_amount sgst_amount igst_amount)
  def fields, do: Enum.map(@fields, fn {key, label, _} -> {key, label} end)
  def required_fields, do: @required

  def suggest(sheet) do
    header =
      Enum.max_by(Enum.take(sheet.rows, 30), fn row -> map_size(mapping(row)) end, fn ->
        %{row: 1, cells: %{}}
      end)

    %{header: header.row, mapping: mapping(header)}
  end

  def mapping(row) do
    Map.new(@fields, fn {key, _, aliases} ->
      matches = Enum.filter(row.cells, fn {_, value} -> normalize(value) in aliases end)

      {key,
       case matches do
         [{column, _}] -> column
         _ -> ""
       end}
    end)
    |> Map.reject(fn {_, column} -> column == "" end)
  end

  def columns(sheet, header) do
    case Enum.find(sheet.rows, &(&1.row == header)) do
      nil ->
        []

      row ->
        sheet.rows
        |> Enum.filter(&(&1.row >= header))
        |> Enum.flat_map(&Map.keys(&1.cells))
        |> Enum.uniq()
        |> Enum.sort_by(&Workbook.column_index/1)
        |> Enum.map(fn col -> {"#{col} — #{display(row.cells[col])}", col} end)
    end
  end

  def subtotal_rows(sheet, header) do
    for row <- sheet.rows,
        row.row > header,
        Enum.any?(Map.values(row.cells), &(normalize(&1) in ~w(total subtotal grandtotal))),
        do: row.row
  end

  def preview(workbook, sheet_name, header, mapping, excluded, client, period) do
    with sheet when not is_nil(sheet) <- Enum.find(workbook.sheets, &(&1.name == sheet_name)),
         true <- Enum.any?(sheet.rows, &(&1.row == header)),
         :ok <- validate_mapping(sheet, header, mapping) do
      rows = Enum.filter(sheet.rows, &(&1.row > header))

      parsed =
        for row <- rows,
            row.row not in excluded,
            do: parse_row(row, mapping, workbook.date1904?, period)

      errors = Enum.flat_map(parsed, & &1.errors)

      groups =
        parsed
        |> Enum.group_by(fn row ->
          {row.values["vendor_gstin"], row.values["invoice_number"], row.values["invoice_date"]}
        end)
        |> Enum.sort_by(fn {_, group} -> hd(group).row end)

      {invoices, group_errors} =
        Enum.map_reduce(groups, [], fn {_, group}, accumulated ->
          {invoice, problems} = invoice(group, sheet_name, client)
          {invoice, accumulated ++ problems}
        end)

      errors = errors ++ group_errors
      totals = Map.new(@amounts, fn key -> {key, sum(Enum.map(parsed, & &1.values[key]))} end)

      controls =
        for row <- rows,
            row.row in excluded,
            Enum.any?(Map.values(row.cells), &(normalize(&1) in ~w(total grandtotal))),
            key <- @amounts,
            source = number(row.cells[mapping[key]]),
            is_number(source) do
          %{
            row: row.row,
            label: label(key),
            source: source,
            included: totals[key],
            difference: (Money.paise(totals[key]) - Money.paise(source)) / 100
          }
        end

      {:ok,
       %{
         invoices: invoices,
         errors: errors,
         totals: totals,
         row_count: length(parsed),
         controls: controls,
         excluded: Enum.filter(rows, &(&1.row in excluded)),
         sheet: sheet.name,
         header: header,
         mapping: mapping,
         other_sheets: Enum.map(Enum.reject(workbook.sheets, &(&1.name == sheet_name)), & &1.name)
       }}
    else
      {:error, message} -> {:error, message}
      _ -> {:error, "Choose a sheet and a header row from this workbook."}
    end
  end

  defp validate_mapping(sheet, header, mapping) do
    columns = columns(sheet, header) |> Enum.map(&elem(&1, 1))
    chosen = mapping |> Map.values() |> Enum.reject(&(&1 in [nil, ""]))

    cond do
      Enum.any?(Map.keys(mapping), &(&1 not in Enum.map(fields(), fn {key, _} -> key end))) ->
        {:error, "Choose only the listed Nila fields."}

      Enum.any?(@required, &(mapping[&1] in [nil, ""])) ->
        {:error, "Match invoice number, date, supplier GSTIN and taxable value."}

      Enum.all?(~w(cgst_amount sgst_amount igst_amount), &(mapping[&1] in [nil, ""])) ->
        {:error, "Match at least one tax amount column. Nila does not invent missing taxes."}

      length(chosen) != length(Enum.uniq(chosen)) ->
        {:error, "Use each source column only once."}

      Enum.any?(chosen, &(&1 not in columns)) ->
        {:error, "A matched column is not in the chosen header row."}

      true ->
        :ok
    end
  end

  defp parse_row(row, mapping, date1904?, _period) do
    raw = Map.new(fields(), fn {key, _} -> {key, Map.get(row.cells, mapping[key], "")} end)

    values =
      Map.new(raw, fn {key, value} ->
        parsed =
          cond do
            key in (@amounts ++ ~w(gst_rate invoice_total)) -> number(value)
            key == "invoice_date" -> date(value, date1904?)
            key == "vendor_gstin" and is_binary(value) -> String.upcase(String.trim(value))
            is_binary(value) -> String.trim(value)
            true -> nil
          end

        {key, parsed}
      end)

    errors =
      Enum.flat_map(fields(), fn {key, label} ->
        value = values[key]

        cond do
          raw[key] in [:formula, :invalid_cell] ->
            ["#{label}: replace formulas or cell errors with values."]

          key in @required and value in [nil, ""] ->
            ["#{label} is missing or invalid."]

          key in (@amounts ++ ~w(gst_rate invoice_total)) and raw[key] not in [nil, ""] and
              is_nil(value) ->
            ["#{label} is not a valid number."]

          key in (@amounts ++ ~w(gst_rate invoice_total)) and is_number(value) and value < 0 ->
            ["#{label} is negative. Credit notes are not supported by this import yet."]

          true ->
            []
        end
      end)

    errors =
      errors ++
        cond do
          values["vendor_gstin"] not in [nil, ""] and
              not Nila.Gstin.valid?(values["vendor_gstin"]) ->
            ["Supplier GSTIN is invalid."]

          true ->
            []
        end

    errors =
      errors ++
        cond do
          normalize(raw["document_type"]) not in [
            "",
            "invoice",
            "taxinvoice",
            "purchase",
            "purchaseinvoice"
          ] ->
            ["Only purchase invoices are supported. This document type needs a separate import."]

          normalize(raw["supply_type"]) not in ["", "taxable", "regular", "b2b", "b2c"] ->
            ["Only ordinary taxable purchases are supported."]

          normalize(raw["reverse_charge"]) not in ["", "no", "n", "false", "0"] ->
            ["Reverse-charge purchases are not supported by this import yet."]

          true ->
            []
        end

    errors =
      if is_number(values["gst_rate"]) and (values["gst_rate"] <= 0 or values["gst_rate"] > 100),
        do:
          errors ++
            [
              "Use a positive GST rate in percentage points, such as 18. Nil-rated purchases are not supported yet."
            ],
        else: errors

    errors =
      if is_number(values["taxable_value"]) and values["taxable_value"] > 0 and
           Enum.all?(~w(cgst_amount sgst_amount igst_amount), &(values[&1] in [nil, 0, 0.0])),
         do:
           errors ++
             [
               "No positive tax amount was found for this taxable purchase. Check the tax columns."
             ],
         else: errors

    errors =
      if (values["cgst_amount"] || 0) > 0 != (values["sgst_amount"] || 0) > 0,
        do: errors ++ ["Map and provide both CGST and SGST for local purchases."],
        else: errors

    %{row: row.row, values: values, errors: Enum.map(errors, &%{row: row.row, message: &1})}
  end

  defp invoice(rows, sheet, _client) do
    first = hd(rows)
    facts = first.values

    identity_fields =
      ~w(vendor_name invoice_total)

    errors =
      Enum.flat_map(identity_fields, fn key ->
        values = rows |> Enum.map(& &1.values[key])

        values =
          if key == "invoice_total", do: Enum.reject(values, &(&1 in [nil, ""])), else: values

        values = Enum.uniq(values)

        if length(values) > 1,
          do: [
            %{
              row: first.row,
              message:
                "Invoice #{facts["invoice_number"]} has conflicting #{label(key)} values. Check the grouping."
            }
          ],
          else: []
      end)

    duplicates = Enum.frequencies_by(rows, & &1.values)

    errors =
      if Enum.any?(duplicates, fn {_, count} -> count > 1 end),
        do:
          errors ++
            [
              %{
                row: first.row,
                message:
                  "Invoice #{facts["invoice_number"]} contains identical rows. Check for duplicates before importing."
              }
            ],
        else: errors

    lines =
      Enum.map(rows, fn row ->
        v = row.values
        rate = v["gst_rate"]
        interstate? = is_number(v["igst_amount"]) and v["igst_amount"] > 0

        %{
          "description" => blank(v["description"]),
          "hsn_sac" => blank(v["hsn_sac"]),
          "printed_taxable_value" => v["taxable_value"],
          "cgst_amount" => v["cgst_amount"],
          "sgst_amount" => v["sgst_amount"],
          "igst_amount" => v["igst_amount"],
          "igst_rate" => if(interstate?, do: rate),
          "cgst_rate" =>
            if(not interstate? and is_number(rate) and is_number(v["cgst_amount"]), do: rate / 2),
          "sgst_rate" =>
            if(not interstate? and is_number(rate) and is_number(v["sgst_amount"]), do: rate / 2)
        }
      end)

    invoice_total = Enum.find_value(rows, & &1.values["invoice_total"])

    data = %{
      "document_type" => "invoice",
      "invoice_number" => facts["invoice_number"],
      "invoice_date" =>
        if(is_struct(facts["invoice_date"], Date), do: Date.to_iso8601(facts["invoice_date"])),
      "seller" => %{
        "name" => blank(facts["vendor_name"]),
        "gstin" => blank(facts["vendor_gstin"])
      },
      "printed_grand_total" => invoice_total,
      "line_items" => lines
    }

    %{"invoices" => [normalized]} = Books.normalize([%{"page" => 1, "data" => data}])

    normalized =
      normalized
      |> Map.put("source_sheet", sheet)
      |> Map.put("source_rows", Enum.map(rows, & &1.row))
      |> Map.put("pages", [])
      |> Map.put("source_pages", [])

    {normalized, errors}
  end

  defp label(key),
    do: Enum.find_value(fields(), key, fn {field, label} -> if field == key, do: label end)

  defp normalize(value) when is_binary(value),
    do: value |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  defp normalize(_), do: ""
  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
  def display(:formula), do: "Formula — paste values"
  def display(:invalid_cell), do: "Cell error"
  def display(value), do: to_string(value || "")

  def source_display(value, column, mapping, date1904?) do
    if mapping["invoice_date"] == column do
      case date(value, date1904?) do
        %Date{} = parsed -> Calendar.strftime(parsed, "%d-%m-%Y")
        _ -> display(value)
      end
    else
      display(value)
    end
  end

  defp number(value) when is_binary(value) do
    cleaned = value |> String.trim() |> String.replace(",", "") |> String.replace("₹", "")

    case Float.parse(cleaned) do
      {number, ""} when abs(number) < 1.0e14 -> number
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp date(value, date1904?) when is_binary(value) do
    case Float.parse(value) do
      {serial, ""} when serial >= 1 and serial < 100_000 ->
        if not date1904? and trunc(serial) == 60,
          do: nil,
          else:
            Date.add(
              if(date1904?,
                do: ~D[1904-01-01],
                else: if(serial < 60, do: ~D[1899-12-31], else: ~D[1899-12-30])
              ),
              trunc(serial)
            )

      _ ->
        Dates.parse_date(value)
    end
  end

  defp date(_, _), do: nil

  defp sum(values),
    do: values |> Enum.map(&Money.paise/1) |> Enum.sum() |> Money.rupees() |> Decimal.to_float()
end
