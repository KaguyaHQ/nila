defmodule Nila.Gst.Sales.WorkingsXlsx do
  @moduledoc """
  Builds the accountant-facing sales working for one GST period.

  The workbook is a projection of the effective sales month. It does not
  calculate a second version of GSTR-1: return tables come from `Gstr1`,
  while the formula cells expose the arithmetic controls a reviewer expects
  to inspect in Excel.
  """

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.{Gstr1, Invoice}

  @money_format "#,##,##0.00;[Red]-#,##,##0.00"
  @integer_format "#,##,##0"
  @percent_format "0.00%"

  @title_format [
    :bold,
    {:font_name, "Arial"},
    {:font_size, 16},
    {:font_color, "#1C2024"}
  ]

  @subtitle_format [
    :italic,
    {:font_name, "Arial"},
    {:font_color, "#60646C"}
  ]

  @header_format [
    :bold,
    :text_wrap,
    {:font_name, "Arial"},
    {:font_color, "#FFFFFF"},
    {:bg_color, "#1F3A5F"},
    {:border, :thin},
    {:border_color, "#D7DBDF"},
    {:align, :center},
    {:valign, :center}
  ]

  @section_format [
    :bold,
    {:font_name, "Arial"},
    {:font_color, "#1C2024"},
    {:bg_color, "#E8EEF6"},
    {:border_bottom, :thin},
    {:border_bottom_color, "#B8C6D9"}
  ]

  @body_format [
    {:font_name, "Arial"},
    {:font_color, "#1C2024"},
    {:valign, :top}
  ]

  @warning_format [
    {:font_name, "Arial"},
    {:font_color, "#8A4B08"},
    {:bg_color, "#FFF1D6"}
  ]

  @type projection :: %{
          required(:derived) => map(),
          required(:invoices) => [map()],
          required(:active_invoices) => [map()]
        }

  @doc "Builds a six-sheet XLSX binary from the effective sales projection."
  @spec build(projection(), map(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, :no_active_sales | :invalid_sales_data | term()}
  def build(projection, client, period, opts \\ []) do
    active = Map.get(projection, :active_invoices, [])

    cond do
      active == [] ->
        {:error, :no_active_sales}

      not valid_client?(client) or not valid_period?(period) ->
        {:error, :invalid_sales_data}

      true ->
        context = context(projection, client, period, opts)

        XlsxWriter.generate([
          summary_sheet(context),
          sales_register_sheet(context),
          tax_breakdown_sheet(context),
          gstr1_working_sheet(context),
          hsn_working_sheet(context),
          exceptions_sheet(context)
        ])
    end
  end

  defp context(projection, client, period, opts) do
    active = projection.active_invoices
    tax_rows = tax_rows(active)
    gstr1_rows = gstr1_rows(projection.derived)
    hsn_rows = hsn_rows(active)

    %{
      projection: projection,
      client: client,
      period: period,
      status: Keyword.get(opts, :status, "Draft"),
      resolutions: Keyword.get(opts, :resolutions, []),
      tax_rows: tax_rows,
      gstr1_rows: gstr1_rows,
      hsn_rows: hsn_rows,
      tax_last_row: max(5, 4 + length(tax_rows)),
      gstr1_last_row: max(5, 4 + length(gstr1_rows)),
      hsn_last_row: max(5, 4 + length(hsn_rows))
    }
  end

  defp summary_sheet(context) do
    all = context.projection.invoices
    active = context.projection.active_invoices
    excluded = length(all) - length(active)
    included = Enum.count(active, &(not is_nil(Gstr1.filing_table(&1))))
    held_out = length(active) - included
    totals = sum_rows(context.gstr1_rows)
    status_format = if context.status == "Draft", do: @warning_format, else: @body_format

    sheet =
      XlsxWriter.new_sheet("Summary")
      |> title(context, "GST sales working")
      |> XlsxWriter.write(3, 0, "Client", format: @section_format)
      |> XlsxWriter.write(3, 1, context.client.name, format: @body_format)
      |> XlsxWriter.write(4, 0, "GSTIN", format: @section_format)
      |> XlsxWriter.write(4, 1, context.client.gstin || "—", format: @body_format)
      |> XlsxWriter.write(5, 0, "Period", format: @section_format)
      |> XlsxWriter.write(5, 1, context.period, format: @body_format)
      |> XlsxWriter.write(6, 0, "Status", format: @section_format)
      |> XlsxWriter.write(6, 1, context.status, format: status_format)
      |> write_headers(9, ["Measure", "Value"])
      |> write_rows(
        10,
        [
          ["Source documents", {:integer, length(all)}],
          ["Included documents", {:integer, included}],
          ["Held out documents", {:integer, held_out}],
          ["Excluded documents", {:integer, excluded}],
          ["Taxable value", {:money, totals.taxable}],
          ["CGST", {:money, totals.cgst}],
          ["SGST", {:money, totals.sgst}],
          ["IGST", {:money, totals.igst}],
          ["Total GST", {:formula, "=SUM(B16:B18)", :money}],
          [
            "Invoice value",
            {:money,
             active
             |> Enum.reject(&is_nil(Gstr1.filing_table(&1)))
             |> Enum.map(&invoice_totals(&1).invoice_value)
             |> Enum.sum()}
          ]
        ]
      )
      |> XlsxWriter.write(20, 0, "GSTR-1 tables", format: @section_format)
      |> write_headers(21, ["Section", "Documents", "Taxable value", "Output tax"])

    {sheet, next_row} =
      Enum.reduce(
        Enum.uniq(~w(B2B B2CL B2CS CDNR) ++ Enum.map(context.gstr1_rows, & &1.section)),
        {sheet, 22},
        fn section, {sheet, row} ->
          sheet =
            write_row(sheet, row, [
              section,
              {:integer, section_document_count(context.projection.active_invoices, section)},
              {:formula,
               "=SUMIF('GSTR-1 Working'!$A$5:$A$#{context.gstr1_last_row},A#{row + 1},'GSTR-1 Working'!$F$5:$F$#{context.gstr1_last_row})",
               :money},
              {:formula,
               "=SUMIF('GSTR-1 Working'!$A$5:$A$#{context.gstr1_last_row},A#{row + 1},'GSTR-1 Working'!$K$5:$K$#{context.gstr1_last_row})",
               :money}
            ])

          {sheet, row + 1}
        end
      )

    sheet
    |> XlsxWriter.write(next_row + 1, 0, "Reconciliation", format: @section_format)
    |> write_headers(next_row + 2, ["Control", "Difference", "Result"])
    |> write_rows(next_row + 3, [
      [
        "Tax Breakdown = GSTR-1 Working",
        {:formula,
         "=SUM('Tax Breakdown'!$J$5:$J$#{context.tax_last_row})-SUM('GSTR-1 Working'!$F$5:$F$#{context.gstr1_last_row})",
         :money},
        {:formula, "=IF(ABS(B#{next_row + 4})<=0.01,\"OK\",\"Check\")", :text}
      ],
      [
        "HSN Working = Tax Breakdown",
        {:formula,
         "=SUM('HSN Working'!$H$5:$H$#{context.hsn_last_row})-SUM('Tax Breakdown'!$J$5:$J$#{context.tax_last_row})",
         :money},
        {:formula, "=IF(ABS(B#{next_row + 5})<=0.01,\"OK\",\"Check\")", :text}
      ],
      [
        "Reported tax = expected tax",
        {:formula,
         "=SUMPRODUCT(ABS('Tax Breakdown'!$M$5:$M$#{context.tax_last_row}))+SUMPRODUCT(ABS('Tax Breakdown'!$P$5:$P$#{context.tax_last_row}))+SUMPRODUCT(ABS('Tax Breakdown'!$S$5:$S$#{context.tax_last_row}))",
         :money},
        {:formula,
         "=IF(COUNTIF('Tax Breakdown'!$U$5:$U$#{context.tax_last_row},\"Missing\")>0,\"Incomplete\",IF(ABS(B#{next_row + 6})<=0.01,\"OK\",\"Check\"))",
         :text}
      ],
      [
        "Tax rows missing reported values",
        {:formula, "=COUNTIF('Tax Breakdown'!$U$5:$U$#{context.tax_last_row},\"Missing\")",
         :integer},
        {:formula, "=IF(B#{next_row + 7}=0,\"OK\",\"Check\")", :text}
      ]
    ])
    |> set_widths([32, 20, 14, 18])
  end

  defp sales_register_sheet(context) do
    headers = [
      "Source",
      "Document no.",
      "Date",
      "Recipient",
      "GSTIN",
      "POS",
      "Document type",
      "Supply type",
      "GSTR-1 section",
      "Invoice value",
      "Taxable value",
      "Printed CGST",
      "Printed SGST",
      "Printed IGST",
      "Status"
    ]

    rows =
      Enum.map(context.projection.active_invoices, &sales_register_row(&1, context.projection))

    XlsxWriter.new_sheet("Sales Register")
    |> title(context, "Sales register")
    |> write_headers(3, headers)
    |> write_rows(4, rows)
    |> table_layout(3, max(4, 3 + length(rows)), length(headers) - 1)
    |> set_widths([16, 18, 13, 28, 18, 9, 16, 14, 24, 16, 16, 14, 14, 14, 14])
  end

  defp tax_breakdown_sheet(context) do
    headers = [
      "Source",
      "Document no.",
      "Date",
      "Recipient",
      "GSTIN",
      "POS",
      "GSTR-1 section",
      "Treatment",
      "Rate",
      "Taxable value",
      "Reported CGST",
      "Expected CGST",
      "Difference",
      "Reported SGST",
      "Expected SGST",
      "Difference",
      "Reported IGST",
      "Expected IGST",
      "Difference",
      "Reported GST",
      "Check"
    ]

    rows =
      context.tax_rows
      |> Enum.with_index(5)
      |> Enum.map(fn {row, excel_row} ->
        [
          row.source,
          row.document,
          {:date, row.date},
          row.recipient,
          row.gstin,
          row.pos,
          row.section,
          row.treatment,
          {:percent, nullable_divide(row.rate, 100)},
          {:money, row.taxable},
          {:money, row.cgst},
          {:formula,
           "=IF(OR(J#{excel_row}=\"\",I#{excel_row}=\"\"),\"\",IF(H#{excel_row}=\"Intrastate\",ROUND(J#{excel_row}*I#{excel_row}/2,2),0))",
           :money},
          {:formula, "=IF(K#{excel_row}=\"\",\"\",K#{excel_row}-L#{excel_row})", :money},
          {:money, row.sgst},
          {:formula,
           "=IF(OR(J#{excel_row}=\"\",I#{excel_row}=\"\"),\"\",IF(H#{excel_row}=\"Intrastate\",ROUND(J#{excel_row}*I#{excel_row}/2,2),0))",
           :money},
          {:formula, "=IF(N#{excel_row}=\"\",\"\",N#{excel_row}-O#{excel_row})", :money},
          {:money, row.igst},
          {:formula,
           "=IF(OR(J#{excel_row}=\"\",I#{excel_row}=\"\"),\"\",IF(H#{excel_row}=\"Interstate\",ROUND(J#{excel_row}*I#{excel_row},2),0))",
           :money},
          {:formula, "=IF(Q#{excel_row}=\"\",\"\",Q#{excel_row}-R#{excel_row})", :money},
          {:formula,
           "=IF(IF(H#{excel_row}=\"Intrastate\",OR(K#{excel_row}=\"\",N#{excel_row}=\"\"),Q#{excel_row}=\"\"),\"\",SUM(K#{excel_row},N#{excel_row},Q#{excel_row}))",
           :money},
          {:formula,
           "=IF(IF(H#{excel_row}=\"Intrastate\",OR(K#{excel_row}=\"\",N#{excel_row}=\"\"),Q#{excel_row}=\"\"),\"Missing\",IF(MAX(ABS(M#{excel_row}),ABS(P#{excel_row}),ABS(S#{excel_row}))<=0.01,\"OK\",\"Check\"))",
           :text}
        ]
      end)

    sheet =
      XlsxWriter.new_sheet("Tax Breakdown")
      |> title(context, "Tax breakdown")
      |> write_headers(3, headers)
      |> write_rows(4, rows)
      |> table_layout(3, max(4, 3 + length(rows)), length(headers) - 1)
      |> set_widths([
        16,
        18,
        13,
        28,
        18,
        9,
        24,
        14,
        10,
        16,
        16,
        16,
        14,
        16,
        16,
        14,
        16,
        16,
        14,
        16,
        12
      ])

    if Enum.any?(context.projection.active_invoices, &Invoice.without_payment?/1),
      do:
        XlsxWriter.write(
          sheet,
          2,
          0,
          "Printed tax includes LUT/bond HSN summaries. GSTR-1 Working shows the tax reported in the return.",
          format: @subtitle_format
        ),
      else: sheet
  end

  defp gstr1_working_sheet(context) do
    headers = [
      "Section",
      "Recipient GSTIN / POS",
      "Document no.",
      "Date",
      "Rate",
      "Taxable value",
      "CGST",
      "SGST",
      "IGST",
      "Cess",
      "Output tax",
      "Invoice value"
    ]

    rows =
      Enum.map(context.gstr1_rows, fn row ->
        [
          row.section,
          row.recipient,
          row.document,
          {:date, row.date},
          {:percent, nullable_divide(row.rate, 100)},
          {:money, row.taxable},
          {:money, row.cgst},
          {:money, row.sgst},
          {:money, row.igst},
          {:money, row.cess},
          {:money, row.tax},
          {:money, row.invoice_value}
        ]
      end)

    sheet =
      XlsxWriter.new_sheet("GSTR-1 Working")
      |> title(context, "GSTR-1 working")
      |> write_headers(3, headers)
      |> write_rows(4, rows)
      |> table_layout(3, max(4, 3 + length(rows)), length(headers) - 1)
      |> set_widths([24, 22, 18, 13, 10, 16, 14, 14, 14, 12, 16, 16])

    write_document_series(sheet, context)
  end

  defp hsn_working_sheet(context) do
    detail_headers = [
      "Document no.",
      "HSN/SAC",
      "Description",
      "UQC",
      "Quantity",
      "Rate",
      "Treatment",
      "Taxable value",
      "Calculated CGST",
      "Calculated SGST",
      "Calculated IGST",
      "Calculated GST"
    ]

    detail_rows =
      context.hsn_rows
      |> Enum.with_index(5)
      |> Enum.map(fn {row, excel_row} ->
        [
          row.document,
          row.hsn,
          row.description,
          row.uqc,
          {:number, row.quantity},
          {:percent, nullable_divide(row.rate, 100)},
          row.treatment,
          {:money, row.taxable},
          {:formula, "=IF(G#{excel_row}=\"Intrastate\",ROUND(H#{excel_row}*F#{excel_row}/2,2),0)",
           :money},
          {:formula, "=IF(G#{excel_row}=\"Intrastate\",ROUND(H#{excel_row}*F#{excel_row}/2,2),0)",
           :money},
          {:formula, "=IF(G#{excel_row}=\"Interstate\",ROUND(H#{excel_row}*F#{excel_row},2),0)",
           :money},
          {:formula, "=SUM(I#{excel_row}:K#{excel_row})", :money}
        ]
      end)

    summary = Gstr1.hsn_summary(context.projection.active_invoices)
    summary_header_row = 6 + length(detail_rows)
    summary_data_row = summary_header_row + 1

    sheet =
      XlsxWriter.new_sheet("HSN Working")
      |> title(context, "HSN working")
      |> write_headers(3, detail_headers)
      |> write_rows(4, detail_rows)
      |> table_layout(3, max(4, 3 + length(detail_rows)), length(detail_headers) - 1)
      |> XlsxWriter.write(summary_header_row - 1, 0, "HSN summary", format: @section_format)
      |> write_headers(summary_header_row, [
        "HSN/SAC",
        "Description",
        "Rate",
        "Taxable value",
        "CGST",
        "SGST",
        "IGST",
        "Total GST"
      ])

    sheet =
      summary
      |> Enum.with_index(summary_data_row)
      |> Enum.reduce(sheet, fn {row, zero_row}, sheet ->
        excel_row = zero_row + 1
        hsn = row["hsn_sc"]
        rate = nullable_divide(row["rt"], 100)

        write_row(sheet, zero_row, [
          hsn,
          row["description"],
          {:percent, rate},
          {:formula,
           "=SUMIFS($H$5:$H$#{context.hsn_last_row},$B$5:$B$#{context.hsn_last_row},A#{excel_row},$F$5:$F$#{context.hsn_last_row},C#{excel_row})",
           :money},
          {:formula,
           "=SUMIFS($I$5:$I$#{context.hsn_last_row},$B$5:$B$#{context.hsn_last_row},A#{excel_row},$F$5:$F$#{context.hsn_last_row},C#{excel_row})",
           :money},
          {:formula,
           "=SUMIFS($J$5:$J$#{context.hsn_last_row},$B$5:$B$#{context.hsn_last_row},A#{excel_row},$F$5:$F$#{context.hsn_last_row},C#{excel_row})",
           :money},
          {:formula,
           "=SUMIFS($K$5:$K$#{context.hsn_last_row},$B$5:$B$#{context.hsn_last_row},A#{excel_row},$F$5:$F$#{context.hsn_last_row},C#{excel_row})",
           :money},
          {:formula, "=SUM(E#{excel_row}:G#{excel_row})", :money}
        ])
      end)

    set_widths(sheet, [18, 16, 38, 18, 16, 16, 16, 16, 16, 16, 16, 16])
  end

  defp exceptions_sheet(context) do
    headers = [
      "Type",
      "Document / source",
      "Field",
      "Original value",
      "Final value",
      "Reason",
      "Reviewer",
      "Date"
    ]

    rows = exception_rows(context)

    rows =
      if rows == [],
        do: [["None", "—", "—", "—", "—", "No exclusions or corrections", "—", nil]],
        else: rows

    XlsxWriter.new_sheet("Exclusions & Corrections")
    |> title(context, "Exclusions and corrections")
    |> write_headers(3, headers)
    |> write_rows(4, rows)
    |> table_layout(3, max(4, 3 + length(rows)), length(headers) - 1)
    |> set_widths([14, 24, 24, 24, 24, 48, 22, 20])
  end

  defp title(sheet, context, title) do
    sheet
    |> XlsxWriter.write(0, 0, title, format: @title_format)
    |> XlsxWriter.write(
      1,
      0,
      "#{context.client.name} · GSTIN #{context.client.gstin || "—"} · #{context.period}",
      format: @subtitle_format
    )
    |> XlsxWriter.set_row_height(0, 24)
  end

  defp table_layout(sheet, header_row, last_row, last_col) do
    sheet
    |> XlsxWriter.freeze_panes(header_row + 1, 0)
    |> XlsxWriter.set_autofilter(header_row, 0, last_row, last_col)
    |> XlsxWriter.set_row_height(header_row, 30)
  end

  defp write_headers(sheet, row, headers) do
    headers
    |> Enum.with_index()
    |> Enum.reduce(sheet, fn {header, col}, sheet ->
      XlsxWriter.write(sheet, row, col, header, format: @header_format)
    end)
  end

  defp write_rows(sheet, first_row, rows) do
    rows
    |> Enum.with_index(first_row)
    |> Enum.reduce(sheet, fn {row, index}, sheet -> write_row(sheet, index, row) end)
  end

  defp write_row(sheet, row, cells) do
    cells
    |> Enum.with_index()
    |> Enum.reduce(sheet, fn {value, col}, sheet -> write_cell(sheet, row, col, value) end)
  end

  defp write_cell(sheet, row, col, {:formula, formula, type}) do
    XlsxWriter.write_formula(sheet, row, col, formula, format: cell_format(type))
  end

  defp write_cell(sheet, row, col, {:money, nil}),
    do: XlsxWriter.write_blank(sheet, row, col, format: cell_format(:money))

  defp write_cell(sheet, row, col, {:money, value}),
    do: XlsxWriter.write(sheet, row, col, value, format: cell_format(:money))

  defp write_cell(sheet, row, col, {:percent, nil}),
    do: XlsxWriter.write_blank(sheet, row, col, format: cell_format(:percent))

  defp write_cell(sheet, row, col, {:percent, value}),
    do: XlsxWriter.write(sheet, row, col, value, format: cell_format(:percent))

  defp write_cell(sheet, row, col, {:integer, value}),
    do: XlsxWriter.write(sheet, row, col, value, format: cell_format(:integer))

  defp write_cell(sheet, row, col, {:number, nil}),
    do: XlsxWriter.write_blank(sheet, row, col, format: cell_format(:number))

  defp write_cell(sheet, row, col, {:number, value}),
    do: XlsxWriter.write(sheet, row, col, value, format: cell_format(:number))

  defp write_cell(sheet, row, col, {:date, nil}),
    do: XlsxWriter.write_blank(sheet, row, col, format: cell_format(:date))

  defp write_cell(sheet, row, col, {:date, value}),
    do: XlsxWriter.write(sheet, row, col, date(value), format: cell_format(:date))

  defp write_cell(sheet, row, col, nil),
    do: XlsxWriter.write_blank(sheet, row, col, format: @body_format)

  defp write_cell(sheet, row, col, value),
    do: XlsxWriter.write(sheet, row, col, display(value), format: @body_format)

  defp cell_format(:money), do: @body_format ++ [{:num_format, @money_format}, {:align, :right}]

  defp cell_format(:integer),
    do: @body_format ++ [{:num_format, @integer_format}, {:align, :right}]

  defp cell_format(:number), do: @body_format ++ [{:num_format, "#,##,##0.00"}, {:align, :right}]

  defp cell_format(:percent),
    do: @body_format ++ [{:num_format, @percent_format}, {:align, :right}]

  defp cell_format(:date), do: @body_format ++ [{:num_format, "dd-mmm-yyyy"}]
  defp cell_format(:text), do: @body_format

  defp set_widths(sheet, widths) do
    widths
    |> Enum.with_index()
    |> Enum.reduce(sheet, fn {width, col}, sheet ->
      XlsxWriter.set_column_width(sheet, col, width)
    end)
  end

  defp sales_register_row(invoice, projection) do
    totals = invoice_totals(invoice)
    section = section(invoice)

    [
      source(invoice),
      Gstr1.document_number(invoice),
      {:date, Gstr1.document_date(invoice)},
      invoice["buyer_name"],
      invoice["buyer_gstin"],
      invoice["place_of_supply"],
      humanize(Gstr1.document_type(invoice)),
      humanize(invoice["supply_type"] || "taxable"),
      section || "Held out",
      {:money, totals.invoice_value},
      {:money, totals.taxable},
      {:money, totals.cgst},
      {:money, totals.sgst},
      {:money, totals.igst},
      invoice_status(invoice, projection, section)
    ]
  end

  defp tax_rows(invoices) do
    invoices
    |> Enum.reject(&is_nil(Gstr1.filing_table(&1)))
    |> Enum.flat_map(fn invoice ->
      effect = Gstr1.document_effect(invoice)

      invoice
      |> Map.get("line_items", [])
      |> List.wrap()
      |> Enum.group_by(fn line -> {line_rate(line), line_treatment(invoice, line)} end)
      |> Enum.map(fn {{rate, treatment}, lines} ->
        taxable = signed_sum_complete(lines, "taxable_value", effect)

        {cgst, sgst, igst} =
          case treatment do
            "Intrastate" ->
              {
                signed_sum_complete(lines, "cgst_amount", effect),
                signed_sum_complete(lines, "sgst_amount", effect),
                0.0
              }

            "Interstate" ->
              {0.0, 0.0, signed_sum_complete(lines, "igst_amount", effect)}
          end

        %{
          source: source(invoice),
          document: Gstr1.document_number(invoice),
          date: Gstr1.document_date(invoice),
          recipient: invoice["buyer_name"],
          gstin: invoice["buyer_gstin"],
          pos: invoice["place_of_supply"],
          section: section(invoice),
          treatment: treatment,
          rate: rate,
          taxable: taxable,
          cgst: cgst,
          sgst: sgst,
          igst: igst,
          tax: number(cgst) + number(sgst) + number(igst)
        }
      end)
    end)
  end

  defp gstr1_rows(derived) do
    b2b =
      for party <- List.wrap(derived["b2b"]),
          invoice <- List.wrap(party["inv"]),
          item <- List.wrap(invoice["itms"]) do
        label =
          case invoice["inv_typ"] do
            "SEWP" -> "SEZ - IGST"
            "SEWOP" -> "SEZ - LUT/bond"
            _ -> if(invoice["rchrg"] == "Y", do: "B2B RCM", else: "B2B")
          end

        return_row(label, party["ctin"], invoice, item["itm_det"] || %{})
      end

    exports =
      for group <- List.wrap(derived["exp"]),
          invoice <- List.wrap(group["inv"]),
          item <- List.wrap(invoice["itms"]) do
        label = if group["exp_typ"] == "WPAY", do: "Export - IGST", else: "Export - LUT/bond"
        return_row(label, nil, invoice, item)
      end

    b2cl =
      for pos <- List.wrap(derived["b2cl"]),
          invoice <- List.wrap(pos["inv"]),
          item <- List.wrap(invoice["itms"]) do
        return_row("B2CL", pos["pos"], invoice, item["itm_det"] || %{})
      end

    b2cs =
      Enum.map(List.wrap(derived["b2cs"]), fn row ->
        return_row("B2CS", row["pos"], %{}, row)
      end)

    cdnr =
      for party <- List.wrap(derived["cdnr"]),
          note <- List.wrap(party["nt"]),
          item <- List.wrap(note["itms"]) do
        effect = if note["ntty"] == "C", do: -1, else: 1
        return_row("CDNR", party["ctin"], note, item["itm_det"] || %{}, effect)
      end

    cdnur =
      for note <- List.wrap(derived["cdnur"]), item <- List.wrap(note["itms"]) do
        effect = if note["ntty"] == "C", do: -1, else: 1
        return_row("CDNUR", note["pos"], note, item["itm_det"] || %{}, effect)
      end

    nil_supplies =
      for row <- get_in(derived, ["nil", "inv"]) || [],
          {field, label} <- [
            {"nil_amt", "Nil-rated"},
            {"expt_amt", "Exempt"},
            {"ngsup_amt", "Non-GST"}
          ],
          number(row[field]) != 0 do
        return_row("Table 8 - " <> label, row["sply_ty"], %{}, %{"txval" => row[field], "rt" => 0})
      end

    b2b ++ exports ++ b2cl ++ b2cs ++ cdnr ++ cdnur ++ nil_supplies
  end

  defp return_row(section, recipient, document, detail, effect \\ 1) do
    cgst = effect * number(detail["camt"])
    sgst = effect * number(detail["samt"])
    igst = effect * number(detail["iamt"])
    cess = effect * number(detail["csamt"])
    taxable = effect * number(detail["txval"])

    %{
      section: section,
      recipient: recipient,
      document: document["inum"] || document["nt_num"],
      date: document["idt"] || document["nt_dt"],
      rate: number(detail["rt"]),
      taxable: taxable,
      cgst: cgst,
      sgst: sgst,
      igst: igst,
      cess: cess,
      tax: cgst + sgst + igst + cess,
      invoice_value: effect * number(document["val"] || taxable + cgst + sgst + igst + cess)
    }
  end

  defp hsn_rows(invoices) do
    invoices
    |> Enum.reject(&is_nil(Gstr1.filing_table(&1)))
    |> Enum.flat_map(fn invoice ->
      effect = Gstr1.document_effect(invoice)

      invoice["line_items"]
      |> List.wrap()
      |> Enum.group_by(fn line ->
        {hsn(line), line_rate(line), uqc(line), line_treatment(invoice, line)}
      end)
      |> Enum.map(fn {{hsn, rate, uqc, line_treatment}, lines} ->
        taxable = effect * Enum.sum(Enum.map(lines, &number(&1["taxable_value"])))

        treatment =
          if Invoice.without_payment?(invoice),
            do: "LUT/bond",
            else: line_treatment

        %{
          document: Gstr1.document_number(invoice),
          hsn: hsn,
          description: common_description(lines),
          uqc: uqc,
          quantity: effect * Enum.sum(Enum.map(lines, &number(&1["quantity"]))),
          rate: rate,
          treatment: treatment,
          taxable: taxable
        }
      end)
    end)
  end

  defp write_document_series(sheet, context) do
    groups = get_in(context.projection.derived, ["doc_issue", "doc_det"]) |> List.wrap()

    rows =
      for group <- groups,
          series <- List.wrap(group["docs"]) do
        [
          document_kind(group["doc_num"]),
          series["from"],
          series["to"],
          {:integer, series["totnum"]},
          {:integer, series["cancel"]},
          {:integer, series["net_issue"]}
        ]
      end

    start = 7 + length(context.gstr1_rows)

    sheet
    |> XlsxWriter.write(start - 1, 0, "Documents issued", format: @section_format)
    |> write_headers(start, ["Document kind", "From", "To", "Total", "Cancelled", "Net issued"])
    |> write_rows(start + 1, rows)
  end

  defp exception_rows(context) do
    held_out =
      context.projection.active_invoices
      |> Enum.filter(&is_nil(Gstr1.filing_table(&1)))
      |> Enum.map(fn invoice ->
        [
          "Held out",
          Gstr1.document_number(invoice) || invoice["id"],
          "GST treatment",
          humanize(invoice["supply_type"] || invoice["document_status"] || "unknown"),
          nil,
          "Current GSTR-1 projection cannot represent this treatment",
          nil,
          nil
        ]
      end)

    resolution_rows =
      context.resolutions
      |> Enum.filter(&(resolution_value(&1, :verb) in ~w(correct_field exclude_duplicate_copy)))
      |> Enum.map(&resolution_row/1)

    held_out ++ resolution_rows
  end

  defp resolution_row(resolution) do
    verb = resolution_value(resolution, :verb)
    payload = resolution_value(resolution, :payload) || %{}

    if verb == "correct_field" do
      [
        "Correction",
        resolution_value(resolution, :target),
        payload["field"],
        display(payload["from"]),
        display(payload["to"]),
        payload["reason"] || "Reviewer corrected extracted value",
        reviewer(resolution),
        resolution_value(resolution, :inserted_at)
      ]
    else
      [
        "Exclusion",
        payload["excluded_source_id"],
        "Duplicate source",
        payload["excluded_source_id"],
        payload["retained_source_id"],
        payload["reason"],
        reviewer(resolution),
        resolution_value(resolution, :inserted_at)
      ]
    end
  end

  defp invoice_totals(invoice) do
    effect = Gstr1.document_effect(invoice)
    lines = List.wrap(invoice["line_items"])
    taxable = effect * Enum.sum(Enum.map(lines, &number(&1["taxable_value"])))
    cgst = effect * Enum.sum(Enum.map(lines, &number(&1["cgst_amount"])))
    sgst = effect * Enum.sum(Enum.map(lines, &number(&1["sgst_amount"])))
    igst = effect * Enum.sum(Enum.map(lines, &number(&1["igst_amount"])))
    tax = cgst + sgst + igst

    invoice_value =
      case invoice["printed_grand_total"] do
        value when is_number(value) -> effect * value
        _other -> taxable + if(Invoice.tax_excluded_from_total?(invoice), do: 0, else: tax)
      end

    %{
      taxable: taxable,
      cgst: cgst,
      sgst: sgst,
      igst: igst,
      tax: tax,
      invoice_value: invoice_value
    }
  end

  defp sum_rows(rows) do
    Enum.reduce(rows, %{taxable: 0.0, cgst: 0.0, sgst: 0.0, igst: 0.0, tax: 0.0}, fn row,
                                                                                     totals ->
      %{
        taxable: totals.taxable + number(row.taxable),
        cgst: totals.cgst + number(row.cgst),
        sgst: totals.sgst + number(row.sgst),
        igst: totals.igst + number(row.igst),
        tax: totals.tax + number(row.tax)
      }
    end)
  end

  defp section_document_count(invoices, section) do
    Enum.count(invoices, &(section(&1) == section))
  end

  defp invoice_status(_invoice, _projection, nil), do: "Held out"

  defp invoice_status(invoice, projection, _section) do
    if Enum.any?(Map.get(projection, :issues, []), fn issue ->
         issue["source_id"] == invoice["id"] and issue["status"] == "open" and
           Issues.gating?(issue)
       end),
       do: "Needs review",
       else: "Included"
  end

  defp section(invoice) do
    case Gstr1.filing_table(invoice) do
      nil ->
        nil

      "b2b" ->
        cond do
          invoice["supply_type"] == "sez" ->
            if(Invoice.without_payment?(invoice), do: "SEZ - LUT/bond", else: "SEZ - IGST")

          Invoice.reverse_charge?(invoice) ->
            "B2B RCM"

          true ->
            "B2B"
        end

      "exp" ->
        if(Invoice.without_payment?(invoice), do: "Export - LUT/bond", else: "Export - IGST")

      value ->
        String.upcase(value)
    end
  end

  defp treatment(invoice, igst) do
    cond do
      Invoice.zero_rated?(invoice) ->
        "Interstate"

      abs(number(igst)) > 0.000_001 ->
        "Interstate"

      state_code(invoice["seller_gstin"]) == state_code(invoice["place_of_supply"]) ->
        "Intrastate"

      true ->
        "Interstate"
    end
  end

  defp source(invoice) do
    invoice["sources"]
    |> List.wrap()
    |> Enum.map(&humanize/1)
    |> Enum.join(" + ")
    |> case do
      "" -> "Document"
      value -> value
    end
  end

  defp hsn(line), do: line["hsn_sac"] |> display() |> String.replace(~r/\D/, "")

  defp line_rate(line) do
    cond do
      is_number(line["igst_rate"]) and line["igst_rate"] > 0 ->
        number(line["igst_rate"])

      is_number(line["cgst_rate"]) or is_number(line["sgst_rate"]) ->
        number(line["cgst_rate"]) + number(line["sgst_rate"])

      true ->
        nil
    end
  end

  defp line_treatment(invoice, line) do
    cond do
      number(line["igst_rate"]) > 0 or number(line["igst_amount"]) > 0 -> "Interstate"
      number(line["cgst_rate"]) > 0 or number(line["sgst_rate"]) > 0 -> "Intrastate"
      true -> treatment(invoice, 0)
    end
  end

  defp signed_sum_complete(lines, field, effect) do
    values = Enum.map(lines, & &1[field])

    if values != [] and Enum.all?(values, &is_number/1),
      do: effect * Enum.sum(values),
      else: nil
  end

  defp nullable_divide(value, divisor) when is_number(value), do: value / divisor
  defp nullable_divide(_value, _divisor), do: nil

  defp uqc(line) do
    value = line["uom"] |> display() |> String.trim() |> String.downcase()

    cond do
      String.starts_with?(hsn(line), "99") -> "NA"
      value in ~w(no nos number numbers pc pcs piece pieces) -> "NOS"
      value in ~w(kg kgs kilogram kilograms) -> "KGS"
      value in ~w(l ltr ltrs litre litres liter liters) -> "LTR"
      value in ~w(m mtr mtrs metre metres meter meters) -> "MTR"
      String.length(value) == 3 -> String.upcase(value)
      true -> "OTH"
    end
  end

  defp common_description(lines) do
    lines
    |> Enum.map(&(&1["hsn_description"] || &1["item_name"] || &1["description"]))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.max_by(fn {_description, count} -> count end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp document_kind(1), do: "Tax invoices"
  defp document_kind(4), do: "Debit notes"
  defp document_kind(5), do: "Credit notes"
  defp document_kind(number), do: "Document type #{number}"

  defp reviewer(%{decided_by: %{name: name}}) when is_binary(name), do: name
  defp reviewer(_resolution), do: nil

  defp resolution_value(resolution, key) when is_map(resolution) do
    Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key))
  end

  defp date(%Date{} = date), do: date
  defp date(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)
  defp date(%DateTime{} = datetime), do: DateTime.to_date(datetime)

  defp date(value) when is_binary(value) do
    normalized = String.replace(value, ~r/[.\/]/, "-")

    case String.split(normalized, "-") do
      [day, month, year] when byte_size(year) == 4 ->
        with {day, ""} <- Integer.parse(day),
             {month, ""} <- Integer.parse(month),
             {year, ""} <- Integer.parse(year),
             {:ok, date} <- Date.new(year, month, day) do
          date
        else
          _invalid -> value
        end

      [year, month, day] when byte_size(year) == 4 ->
        case Date.from_iso8601(Enum.join([year, month, day], "-")) do
          {:ok, date} -> date
          {:error, _reason} -> value
        end

      _other ->
        value
    end
  end

  defp date(value), do: value

  defp state_code(value) when is_binary(value), do: String.slice(String.trim(value), 0, 2)
  defp state_code(_value), do: nil

  defp humanize(nil), do: "—"

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp display(nil), do: ""
  defp display(value) when is_binary(value), do: value
  defp display(value), do: to_string(value)

  defp number(value) when is_integer(value), do: value * 1.0
  defp number(value) when is_float(value), do: value
  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(_value), do: 0.0

  defp valid_client?(%{name: name}) when is_binary(name), do: String.trim(name) != ""
  defp valid_client?(_client), do: false

  defp valid_period?(<<year::binary-size(4), "-", month::binary-size(2)>>) do
    with {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {:ok, _date} <- Date.new(year, month, 1) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_period?(_period), do: false
end
