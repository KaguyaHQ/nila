defmodule Nila.ExcelTemplates do
  @headers [
    "Invoice number",
    "Invoice date",
    "Customer",
    "Customer GSTIN",
    "Place of supply",
    "HSN/SAC",
    "Item description",
    "Taxable value",
    "GST rate",
    "CGST",
    "SGST",
    "IGST",
    "Invoice total",
    "Customer registration"
  ]
  @purchase_headers [
    "Invoice number",
    "Invoice date",
    "Supplier",
    "Supplier GSTIN",
    "HSN/SAC",
    "Item description",
    "Taxable value",
    "GST rate",
    "CGST",
    "SGST",
    "IGST",
    "Invoice total"
  ]
  @body [{:font_name, "Arial"}, {:font_size, 10}]
  @header [:bold, {:bg_color, "#E8EEF8"}, {:valign, :center} | @body]

  def run do
    sales = [
      [
        "DEMO-001",
        ~D[2026-08-05],
        "Example local customer",
        "",
        "33",
        "998719",
        "Repair service",
        1000,
        18,
        90,
        90,
        0,
        1180,
        "unregistered"
      ],
      [
        "DEMO-002",
        ~D[2026-08-08],
        "Example interstate customer",
        "29AAVCS8021P1ZB",
        "29",
        "998719",
        "Repair service",
        2000,
        18,
        0,
        0,
        360,
        3410,
        "registered"
      ],
      [
        "DEMO-002",
        ~D[2026-08-08],
        "Example interstate customer",
        "29AAVCS8021P1ZB",
        "29",
        "8471",
        "Equipment",
        1000,
        5,
        0,
        0,
        50,
        3410,
        "registered"
      ]
    ]

    purchases = [
      [
        "DEMO-P001",
        ~D[2026-09-05],
        "Example local supplier",
        "33AAAAA0000A1Z9",
        "998719",
        "Repair service",
        1000,
        18,
        90,
        90,
        0,
        1180
      ],
      [
        "DEMO-P002",
        ~D[2026-09-08],
        "Example interstate supplier",
        "29BBBBB0000B1ZP",
        "998719",
        "Repair service",
        2000,
        18,
        0,
        0,
        360,
        3410
      ],
      [
        "DEMO-P002",
        ~D[2026-09-08],
        "Example interstate supplier",
        "29BBBBB0000B1ZP",
        "5201",
        "Cotton",
        1000,
        5,
        0,
        0,
        50,
        3410
      ]
    ]

    write("Sales", @headers, sales, Nila.Gst.Sales.Excel)
    write("Purchases", @purchase_headers, purchases, Nila.Gst.Purchase.Excel)
  end

  defp write(name, headers, rows, importer) do
    required_columns =
      importer.mapping(%{
        cells: headers |> Enum.with_index() |> Map.new(fn {header, col} -> {col, header} end)
      })
      |> Map.take(importer.required_fields())
      |> Map.values()

    notes = [
      "* Required. Synthetic examples. Fill the #{name} sheet with your own transactions. Amounts in INR.",
      "Repeat invoice details for each item or tax rate. GST rate: enter 18 for 18%. Paste values, not formulas.",
      "Taxable value and tax amounts are per row. Use 0 for a tax that does not apply.",
      "Invoice total is for the whole invoice: enter once or repeat unchanged.",
      "Ordinary taxable invoices only. Credit notes, exempt supplies and reverse charge need a separate path."
    ]

    sheets = [
      sheet(name, headers, [], ["* Required"], required_columns),
      sheet("Example", headers, rows, notes, required_columns)
    ]

    {:ok, bytes} = XlsxWriter.generate(sheets)

    directory =
      System.get_env("NILA_TEMPLATE_OUTPUT") || Path.expand("../../priv/templates", __DIR__)

    File.mkdir_p!(directory)
    path = Path.join(directory, "Nila-#{String.downcase(name)}-template.xlsx")

    File.write!(path, bytes)
    IO.puts("Generated #{path}")
  end

  defp sheet(name, headers, rows, notes, required_columns) do
    offset = length(notes)
    sheet = XlsxWriter.new_sheet(name) |> XlsxWriter.freeze_panes(offset + 1, 0)

    sheet =
      notes
      |> Enum.with_index()
      |> Enum.reduce(sheet, fn {note, row}, sheet ->
        note_format =
          if String.starts_with?(note, "* Required"),
            do: [{:font_name, "Arial"}, {:font_size, 9}, {:font_color, "#666666"}],
            else: @body

        sheet
        |> XlsxWriter.merge_range(row, 0, row, length(headers) - 1, note, format: note_format)
        |> XlsxWriter.set_row_height(row, 18)
      end)

    sheet =
      headers
      |> Enum.with_index()
      |> Enum.reduce(sheet, fn {header, col}, sheet ->
        required? = col in required_columns
        label = if required?, do: header <> " *", else: header

        sheet
        |> XlsxWriter.write(offset, col, label, format: @header)
        |> XlsxWriter.set_column_width(col, width(header) + if(required?, do: 2, else: 0))
      end)

    sheet = XlsxWriter.set_row_height(sheet, offset, 20)
    # Format blank entry rows too: identifiers stay text, dates and amounts display consistently.
    sheet =
      Enum.reduce((offset + 1)..(offset + 100), sheet, fn row, sheet ->
        headers
        |> Enum.with_index()
        |> Enum.reduce(sheet, fn {header, col}, sheet ->
          XlsxWriter.write_blank(sheet, row, col, format: format(header))
        end)
      end)

    rows
    |> Enum.with_index(offset + 1)
    |> Enum.reduce(sheet, fn {values, row}, sheet ->
      values
      |> Enum.with_index()
      |> Enum.reduce(sheet, fn {value, col}, sheet ->
        XlsxWriter.write(sheet, row, col, value, format: format(Enum.at(headers, col)))
      end)
    end)
  end

  defp width(header) do
    case header do
      h when h in ["Customer", "Supplier"] -> 26
      h when h in ["Customer GSTIN", "Supplier GSTIN"] -> 21
      "Item description" -> 19
      "Customer registration" -> 22
      "Place of supply" -> 17
      "Invoice number" -> 17
      "Invoice date" -> 14
      "Taxable value" -> 15
      "Invoice total" -> 14
      _ -> 10
    end
  end

  defp format(header) do
    number_format =
      case header do
        "Invoice date" -> "dd-mmm-yyyy"
        "GST rate" -> "General"
        h when h in ["Taxable value", "CGST", "SGST", "IGST", "Invoice total"] -> "#,##0.00"
        _ -> "@"
      end

    [{:num_format, number_format} | @body]
  end
end

Nila.ExcelTemplates.run()
