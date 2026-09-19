defmodule Nila.Gst.Sales.Workings.Xlsx do
  @moduledoc """
  Builds the accountant-facing sales working for one GST period.

  The workbook is a projection of the effective sales month. It does not
  calculate a second version of GSTR-1. Formula cells expose the arithmetic controls a reviewer expects
  to inspect in Excel.
  """

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.{Gstr1, Invoice}

  @money_format "#,##,##0.00;(#,##,##0.00);\"-\""
  @difference_format "[>0.01][Red]#,##,##0.00;[<-0.01][Red]-#,##,##0.00;\"-\""
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
    {:font_color, "#1C2024"},
    {:bg_color, "#D9D9D9"},
    {:border, :thin},
    {:border_color, "#D7DBDF"},
    {:align, :center},
    {:valign, :center}
  ]

  @section_format [
    :bold,
    {:font_name, "Arial"},
    {:font_color, "#1C2024"},
    {:bg_color, "#E7E7E7"},
    {:border_bottom, :thin},
    {:border_bottom_color, "#B8B8B8"}
  ]

  # Leave body row heights unset so Excel fits wrapped text using the actual font.
  @body_format [
    :text_wrap,
    {:font_name, "Arial"},
    {:font_color, "#1C2024"},
    {:valign, :top}
  ]

  @type projection :: %{
          required(:derived) => map(),
          required(:invoices) => [map()],
          required(:active_invoices) => [map()]
        }

  @doc "Builds a sales, tax and HSN XLSX binary from the effective sales projection."
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

        sheets = [
          consolidation_sheet(context),
          invoice_check_sheet(context),
          sales_register_sheet(context),
          hsn_working_sheet(context),
          tax_breakdown_sheet(context)
        ]

        sheets =
          if exception_rows(context) == [],
            do: sheets,
            else: sheets ++ [exceptions_sheet(context)]

        XlsxWriter.generate(sheets)
    end
  end

  defp context(projection, client, period, opts) do
    active = projection.active_invoices
    tax_rows = tax_rows(active)
    hsn_rows = hsn_rows(active)

    %{
      projection: projection,
      client: client,
      period: period,
      status: Keyword.get(opts, :status, "Draft"),
      resolutions: Keyword.get(opts, :resolutions, []),
      invoice_urls: Keyword.get(opts, :invoice_urls, %{}),
      tax_rows: tax_rows,
      hsn_rows: hsn_rows,
      tax_last_row: max(5, 4 + length(tax_rows)),
      hsn_last_row: max(5, 4 + length(hsn_rows))
    }
  end

  # These two reading views share the existing arithmetic instead of maintaining
  # a second tax calculation. Invoice totals remain once per document in Sales.
  defp consolidation_sheet(context) do
    groups = check_groups(context)

    sheet =
      XlsxWriter.new_sheet("Consolidation")
      |> title(context, "Sales consolidation")
      |> XlsxWriter.write(
        2,
        0,
        "Taxable value and tax by sales category. Blank amounts are incomplete.",
        format: @subtitle_format
      )
      |> write_headers(3, [
        "GSTR-1 table",
        "Supply",
        "Rate",
        "Taxable value",
        "CGST",
        "SGST",
        "IGST"
      ])
      |> set_widths([23, 15, 10, 18, 16, 16, 16])
      |> XlsxWriter.freeze_panes(4, 0)
      |> XlsxWriter.set_row_height(3, 26)

    sheet =
      groups
      |> Enum.with_index(4)
      |> Enum.reduce(sheet, fn {{section, supply, rate}, row}, sheet ->
        cells =
          [section, supply, {:percent, nullable_divide(rate, 100)}] ++
            Enum.map(~w(J K N Q), fn column ->
              {:formula, group_sum(column, row + 1, context.tax_last_row), :key_money}
            end)

        write_row(sheet, row, cells)
      end)

    total = 5 + length(groups)

    sheet =
      sheet
      |> write_row(
        total,
        ["Total sales", nil, nil] ++
          Enum.map(3..6, fn col ->
            {:formula, complete_range_sum(column(col), 5, 4 + length(groups)), :total_money}
          end)
      )
      |> shade_row(total, 6)

    last = 4 + length(context.projection.active_invoices)

    counts = [
      ["Source documents", {:integer, length(context.projection.invoices)}],
      ["Included", {:formula, "=COUNTIF('Sales'!O5:O#{last},\"Included\")", :integer}],
      ["Needs review", {:formula, "=COUNTIF('Sales'!O5:O#{last},\"Needs review\")", :integer}],
      ["Held out", {:formula, "=COUNTIF('Sales'!O5:O#{last},\"Held out\")", :integer}],
      [
        "Excluded",
        {:integer,
         length(context.projection.invoices) - length(context.projection.active_invoices)}
      ]
    ]

    sheet =
      sheet
      |> write_headers(total + 3, ["Documents", "Count"])
      |> XlsxWriter.set_row_height(total + 3, 22)
      |> write_rows(total + 4, counts)

    sheet = write_document_series(sheet, context, total + 14)

    if Enum.any?(context.projection.active_invoices, &is_nil(Gstr1.filing_table(&1))) do
      XlsxWriter.write(
        sheet,
        total + 10,
        0,
        "Held-out documents are in Sales and Review Trail, outside the totals above.",
        format: @subtitle_format
      )
    else
      sheet
    end
  end

  defp invoice_check_sheet(context) do
    sheet =
      XlsxWriter.new_sheet("Tax Working")
      |> title(context, "Invoice tax checks")
      |> XlsxWriter.write(
        2,
        0,
        "Amounts: dash = zero; blank = missing. Tax checks: dash = within 1 paisa. Click an invoice for its bill in Nila; click a tax check for calculations.",
        format: @subtitle_format
      )
      |> write_headers(3, [
        "Invoice no.",
        "Date",
        "Customer",
        "Taxable value",
        "CGST",
        "SGST",
        "IGST",
        "CGST check",
        "SGST check",
        "IGST check",
        "Review"
      ])
      |> XlsxWriter.set_row_height(3, 30)
      |> set_widths([18, 13, 32, 16, 13, 13, 13, 8, 8, 8, 18])
      |> XlsxWriter.freeze_panes(4, 2)

    {sheet, _next} =
      Enum.reduce(check_groups(context), {sheet, 4}, fn group, {sheet, start} ->
        {section, supply, rate} = group
        rows = group_rows(context, group)
        heads = [{"CGST", "K", "M"}, {"SGST", "N", "P"}, {"IGST", "Q", "S"}]

        name =
          "#{section} · #{supply} @ #{if is_number(rate), do: display(rate) <> "%", else: "Missing rate"}"

        sheet = XlsxWriter.merge_range(sheet, start, 0, start, 10, name, format: @section_format)

        sheet =
          rows
          |> Enum.with_index(start + 1)
          |> Enum.reduce(sheet, fn {{data, source_row}, row}, sheet ->
            amounts =
              Enum.map(heads, fn {_, value_col, _} ->
                linked_number(value_col, source_row, :money)
              end)

            checks =
              Enum.map(heads, fn {_, _, diff_col} ->
                {:formula,
                 "=HYPERLINK(\"#'Calculations'!#{diff_col}#{source_row}\",IF(ISNUMBER('Calculations'!#{diff_col}#{source_row}),'Calculations'!#{diff_col}#{source_row},\"\"))",
                 :difference}
              end)

            source_issue = source_review(context, data.source_id)

            review =
              {:formula,
               "=IF('Calculations'!U#{source_row}=\"OK\",\"#{source_issue}\",'Calculations'!U#{source_row})",
               if(
                 source_issue != "" or
                   Enum.any?(
                     [data.taxable, data.rate, data.cgst, data.sgst, data.igst],
                     &is_nil/1
                   ),
                 do: :warning,
                 else: :text
               )}

            sheet =
              write_row(
                sheet,
                row,
                [
                  data.document,
                  {:date, data.date},
                  data.recipient,
                  linked_number("J", source_row, :key_money)
                ] ++ amounts ++ checks ++ [review]
              )

            link_invoice(sheet, row, data.source_id, data.document, context)
          end)

        first = start + 2
        last = start + 1 + length(rows)
        total_row = last

        sheet =
          write_row(
            sheet,
            total_row,
            ["Subtotal", nil, nil] ++
              Enum.map(3..(3 + length(heads)), fn col ->
                {:formula, complete_range_sum(column(col), first, last), :total_money}
              end)
          )
          |> shade_row(total_row, 10)

        {sheet, total_row + 3}
      end)

    sheet
  end

  defp link_invoices(sheet, rows, context, identity, label) do
    rows
    |> Enum.with_index(4)
    |> Enum.reduce(sheet, fn {row, index}, sheet ->
      link_invoice(sheet, index, identity.(row), label.(row), context)
    end)
  end

  defp link_invoice(sheet, row, source_id, label, context) do
    case Map.get(context.invoice_urls, source_id) do
      url when is_binary(url) ->
        XlsxWriter.write_url(sheet, row, 0, url,
          text: label || "View bill",
          format: @body_format ++ [{:font_color, "#365F7D"}]
        )

      _ ->
        sheet
    end
  end

  defp source_review(context, source_id) do
    issue =
      Enum.find(Map.get(context.projection, :issues, []), fn issue ->
        issue["source_id"] == source_id and issue["status"] == "open" and Issues.gating?(issue)
      end)

    if issue, do: "Review source", else: ""
  end

  defp check_groups(context) do
    context.tax_rows
    |> Enum.map(&{&1.section, &1.treatment, &1.rate})
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp group_rows(context, group) do
    context.tax_rows
    |> Enum.with_index(5)
    |> Enum.filter(fn {row, _} -> {row.section, row.treatment, row.rate} == group end)
  end

  defp linked_number(column, row, type) do
    reference = "'Calculations'!#{column}#{row}"
    {:formula, "=IF(ISNUMBER(#{reference}),#{reference},\"\")", type}
  end

  defp group_sum(column, row, last) do
    criteria =
      "'Calculations'!$G$5:$G$#{last},A#{row},'Calculations'!$H$5:$H$#{last},B#{row},'Calculations'!$I$5:$I$#{last},IF(ISNUMBER(C#{row}),C#{row},\"\")"

    values = "'Calculations'!$#{column}$5:$#{column}$#{last}"
    "=IF(COUNTIFS(#{criteria},#{values},\"\")>0,\"\",SUMIFS(#{values},#{criteria}))"
  end

  defp complete_range_sum(_column, first, last) when last < first, do: "=0"

  defp complete_range_sum(column, first, last) do
    range = "#{column}#{first}:#{column}#{last}"
    "=IF(COUNT(#{range})<#{last - first + 1},\"\",SUM(#{range}))"
  end

  defp column(index), do: <<?A + index>>

  # Keep written values and formulas; change only their existing format.
  defp shade_row({name, instructions}, row, last_col) do
    instructions =
      Enum.map(instructions, fn
        {:write, ^row, col, {kind, value, format}} when col <= last_col ->
          {:write, row, col, {kind, value, format ++ @section_format}}

        {:write, ^row, col, {:blank, format}} when col <= last_col ->
          {:write, row, col, {:blank, format ++ @section_format}}

        instruction ->
          instruction
      end)

    {name, instructions}
  end

  defp sales_register_sheet(context) do
    headers = [
      "Invoice no.",
      "Date",
      "Customer",
      "GSTIN",
      "Place of supply",
      "Rates",
      "Taxable value",
      "Source CGST",
      "Source SGST",
      "Source IGST",
      "Invoice value",
      "Document type",
      "Supply type",
      "GSTR-1 table",
      "Status",
      "Source"
    ]

    rows =
      Enum.map(context.projection.active_invoices, &sales_register_row(&1, context.projection))

    XlsxWriter.new_sheet("Sales")
    |> title(context, "Sales register")
    |> write_headers(3, headers)
    |> write_rows(4, rows)
    |> table_layout(3, max(4, 3 + length(rows)), length(headers) - 1)
    |> link_invoices(
      context.projection.active_invoices,
      context,
      & &1["id"],
      &Invoice.document_number/1
    )
    |> sales_totals(length(rows))
    |> population_counts(context, length(rows) + 8)
    |> set_widths([18, 13, 34, 22, 10, 14, 16, 14, 14, 14, 16, 14, 14, 22, 16, 28])
  end

  defp tax_breakdown_sheet(context) do
    headers = [
      "Invoice no.",
      "Date",
      "Customer",
      "GSTIN",
      "Place of supply",
      "Document type",
      "GSTR-1 table",
      "Supply",
      "Rate",
      "Taxable value",
      "Source CGST",
      "Calculated CGST",
      "Difference",
      "Source SGST",
      "Calculated SGST",
      "Difference",
      "Source IGST",
      "Calculated IGST",
      "Difference",
      "Source GST",
      "Review",
      "Source"
    ]

    rows =
      context.tax_rows
      |> Enum.with_index(5)
      |> Enum.map(fn {row, excel_row} ->
        rounding_check = rounding_check(row, context, excel_row)

        [
          row.document,
          {:date, row.date},
          row.recipient,
          row.gstin,
          row.pos,
          row.document_type,
          row.section,
          row.treatment,
          {:percent, nullable_divide(row.rate, 100)},
          {:money, row.taxable},
          {:money, row.cgst},
          {:formula,
           "=IF(COUNT(J#{excel_row},I#{excel_row})<2,\"\",IF(H#{excel_row}=\"Intrastate\",ROUND(J#{excel_row}*I#{excel_row}/2,2),0))",
           :money},
          {:formula, "=IF(COUNT(K#{excel_row},L#{excel_row})<2,\"\",K#{excel_row}-L#{excel_row})",
           :money},
          {:money, row.sgst},
          {:formula,
           "=IF(COUNT(J#{excel_row},I#{excel_row})<2,\"\",IF(H#{excel_row}=\"Intrastate\",ROUND(J#{excel_row}*I#{excel_row}/2,2),0))",
           :money},
          {:formula, "=IF(COUNT(N#{excel_row},O#{excel_row})<2,\"\",N#{excel_row}-O#{excel_row})",
           :money},
          {:money, row.igst},
          {:formula,
           "=IF(COUNT(J#{excel_row},I#{excel_row})<2,\"\",IF(H#{excel_row}=\"Interstate\",ROUND(J#{excel_row}*I#{excel_row},2),0))",
           :money},
          {:formula, "=IF(COUNT(Q#{excel_row},R#{excel_row})<2,\"\",Q#{excel_row}-R#{excel_row})",
           :money},
          {:formula,
           "=IF(COUNT(K#{excel_row},N#{excel_row},Q#{excel_row})<3,\"\",SUM(K#{excel_row},N#{excel_row},Q#{excel_row}))",
           :money},
          {:formula,
           "=IF(COUNT(J#{excel_row},I#{excel_row},K#{excel_row},N#{excel_row},Q#{excel_row})<5,\"Missing\",IF(MAX(ABS(M#{excel_row}),ABS(P#{excel_row}),ABS(S#{excel_row}))<=0.01,\"OK\",#{rounding_check}))",
           :text},
          row.source
        ]
      end)

    sheet =
      XlsxWriter.new_sheet("Calculations")
      |> title(context, "Tax calculations")
      |> write_headers(3, headers)
      |> write_rows(4, rows)
      |> link_invoices(context.tax_rows, context, & &1.source_id, & &1.document)
      |> table_layout(3, max(4, 3 + length(rows)), length(headers) - 1)
      |> set_widths([
        18,
        13,
        34,
        22,
        10,
        14,
        22,
        14,
        10,
        16,
        14,
        14,
        12,
        14,
        14,
        12,
        14,
        14,
        12,
        14,
        20,
        28
      ])

    sheet
    |> XlsxWriter.write(
      2,
      0,
      "Source = reviewed invoice amounts. Calculated = taxable value x tax rate.",
      format: @subtitle_format
    )
  end

  defp sales_totals(sheet, count) do
    last = 4 + count

    sheet =
      XlsxWriter.write(sheet, last + 1, 0, "Visible total (blank means incomplete)",
        format: @section_format
      )

    Enum.reduce(6..10, sheet, fn col, sheet ->
      letter = <<?A + col>>

      write_cell(
        sheet,
        last + 1,
        col,
        {:formula,
         "=IF(SUBTOTAL(102,#{letter}5:#{letter}#{last})<SUBTOTAL(103,$O$5:$O$#{last}),\"\",SUBTOTAL(109,#{letter}5:#{letter}#{last}))",
         :money}
      )
    end)
  end

  defp population_counts(sheet, context, start) do
    last = 4 + length(context.projection.active_invoices)

    sheet
    |> write_headers(start, ["Documents", "Count"])
    |> write_rows(start + 1, [
      ["Source documents", {:integer, length(context.projection.invoices)}],
      ["Included", {:formula, "=COUNTIF(O5:O#{last},\"Included\")", :integer}],
      ["Needs review", {:formula, "=COUNTIF(O5:O#{last},\"Needs review\")", :integer}],
      ["Held out", {:formula, "=COUNTIF(O5:O#{last},\"Held out\")", :integer}],
      [
        "Excluded",
        {:integer,
         length(context.projection.invoices) - length(context.projection.active_invoices)}
      ]
    ])
  end

  defp hsn_working_sheet(context) do
    detail_headers = [
      "Invoice no.",
      "HSN/SAC",
      "Description",
      "UQC",
      "Quantity",
      "Rate",
      "Supply",
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
          {:formula,
           "=IF(COUNT(H#{excel_row},F#{excel_row})<2,\"\",IF(G#{excel_row}=\"Intrastate\",ROUND(H#{excel_row}*F#{excel_row}/2,2),0))",
           :money},
          {:formula,
           "=IF(COUNT(H#{excel_row},F#{excel_row})<2,\"\",IF(G#{excel_row}=\"Intrastate\",ROUND(H#{excel_row}*F#{excel_row}/2,2),0))",
           :money},
          {:formula,
           "=IF(COUNT(H#{excel_row},F#{excel_row})<2,\"\",IF(G#{excel_row}=\"Interstate\",ROUND(H#{excel_row}*F#{excel_row},2),0))",
           :money},
          {:formula,
           "=IF(COUNT(I#{excel_row}:K#{excel_row})<3,\"\",SUM(I#{excel_row}:K#{excel_row}))",
           :money}
        ]
      end)

    summary = context.hsn_rows |> Enum.group_by(&{&1.hsn, &1.rate, &1.uqc}) |> Enum.sort()
    summary_header_row = 6 + length(detail_rows)
    summary_data_row = summary_header_row + 1

    sheet =
      XlsxWriter.new_sheet("HSN")
      |> title(context, "HSN working")
      |> write_headers(3, detail_headers)
      |> write_rows(4, detail_rows)
      |> link_invoices(context.hsn_rows, context, & &1.source_id, & &1.document)
      |> table_layout(3, max(4, 3 + length(detail_rows)), length(detail_headers) - 1)
      |> XlsxWriter.write(summary_header_row - 1, 0, "HSN summary (blank totals are incomplete)",
        format: @section_format
      )
      |> write_headers(summary_header_row, [
        "",
        "HSN/SAC",
        "Description",
        "UQC",
        "Quantity",
        "Rate",
        "",
        "Taxable value",
        "CGST",
        "SGST",
        "IGST",
        "Total GST"
      ])

    sheet =
      summary
      |> Enum.with_index(summary_data_row)
      |> Enum.reduce(sheet, fn {{{hsn, rate, uqc}, rows}, zero_row}, sheet ->
        excel = zero_row + 1

        formulas =
          for col <- ~w(E H I J K),
              do:
                {:formula,
                 "=IF(OR(NOT(ISNUMBER(F#{excel})),COUNTIFS($B$5:$B$#{context.hsn_last_row},B#{excel},$F$5:$F$#{context.hsn_last_row},F#{excel},$D$5:$D$#{context.hsn_last_row},D#{excel},$#{col}$5:$#{col}$#{context.hsn_last_row},\"\")>0),\"\",SUMIFS($#{col}$5:$#{col}$#{context.hsn_last_row},$B$5:$B$#{context.hsn_last_row},B#{excel},$F$5:$F$#{context.hsn_last_row},F#{excel},$D$5:$D$#{context.hsn_last_row},D#{excel}))",
                 :money}

        description =
          rows
          |> Enum.map(& &1.description)
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.uniq()
          |> case do
            [description] -> description
            [] -> nil
            _multiple -> "See invoice detail"
          end

        write_row(
          sheet,
          zero_row,
          [nil, hsn, description, uqc, hd(formulas), {:percent, nullable_divide(rate, 100)}, nil] ++
            tl(formulas) ++
            [
              {:formula, "=IF(COUNT(I#{excel}:K#{excel})<3,\"\",SUM(I#{excel}:K#{excel}))",
               :money}
            ]
        )
      end)

    sheet
    |> set_widths([18, 13, 34, 10, 12, 10, 14, 16, 14, 14, 14, 14])
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

    XlsxWriter.new_sheet("Review Trail")
    |> title(context, "Review trail")
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
      "#{context.client.name} · GSTIN #{context.client.gstin || "—"} · #{context.period} | #{context.status}",
      format: @subtitle_format
    )
    |> XlsxWriter.set_row_height(0, 24)
  end

  defp table_layout(sheet, header_row, last_row, last_col) do
    sheet
    |> XlsxWriter.freeze_panes(header_row + 1, 2)
    |> XlsxWriter.set_autofilter(header_row, 0, last_row, last_col)
    |> XlsxWriter.set_row_height(header_row, 42)
  end

  defp write_headers(sheet, row, headers) do
    headers
    |> Enum.with_index()
    |> Enum.reduce(XlsxWriter.set_row_height(sheet, row, 42), fn {header, col}, sheet ->
      XlsxWriter.write(sheet, row, col, header, format: @header_format)
    end)
  end

  defp write_rows(sheet, first_row, rows) do
    rows
    |> Enum.with_index(first_row)
    |> Enum.reduce(sheet, fn {row, index}, sheet ->
      write_row(sheet, index, row)
    end)
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

  defp cell_format(:key_money), do: cell_format(:money) ++ [{:bg_color, "#EFEFEF"}]
  defp cell_format(:total_money), do: cell_format(:key_money) ++ [:bold]

  defp cell_format(:difference),
    do:
      @body_format ++
        [{:num_format, @difference_format}, {:align, :right}, {:font_color, "#60646C"}]

  defp cell_format(:integer),
    do: @body_format ++ [{:num_format, @integer_format}, {:align, :right}]

  defp cell_format(:number), do: @body_format ++ [{:num_format, "#,##,##0.00"}, {:align, :right}]

  defp cell_format(:percent),
    do: @body_format ++ [{:num_format, @percent_format}, {:align, :right}]

  defp cell_format(:date), do: @body_format ++ [{:num_format, "dd-mmm-yyyy"}]
  defp cell_format(:text), do: @body_format
  defp cell_format(:warning), do: @body_format ++ [{:bg_color, "#FFF2CC"}]

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

    rates =
      invoice["line_items"]
      |> List.wrap()
      |> Enum.map(&working_rate(invoice, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join(", ", &(display(&1) <> "%"))

    [
      Invoice.document_number(invoice),
      {:date, Invoice.document_date(invoice)},
      invoice["buyer_name"],
      invoice["buyer_gstin"],
      filing_pos(invoice),
      rates,
      {:money, totals.taxable},
      {:money, totals.cgst},
      {:money, totals.sgst},
      {:money, totals.igst},
      {:money, totals.invoice_value},
      humanize(Invoice.document_type(invoice)),
      humanize(invoice["supply_type"] || "taxable"),
      section || "Held out",
      invoice_status(invoice, projection, section),
      source(invoice)
    ]
  end

  defp issue_document(context, issue) do
    target = issue["source_id"] || issue["target"]

    case Enum.find(context.projection.invoices, &(&1["id"] == target)) do
      nil -> target || "Month"
      invoice -> Invoice.document_number(invoice) || target
    end
  end

  defp issue_message(issue) do
    (issue["message"] || issue["description"] || humanize(issue["code"] || "Unresolved issue"))
    |> String.replace("camt", "CGST")
    |> String.replace("samt", "SGST")
    |> String.replace("iamt", "IGST")
  end

  defp rounding_check(row, context, excel_row) do
    info? =
      Enum.any?(
        Map.get(context.projection, :issues, []),
        &(&1["source_id"] == row.source_id and &1["code"] == "rounding_variance" and
            Issues.level(&1) == "info")
      )

    if info? and Enum.all?([row.taxable, row.rate, row.cgst, row.sgst, row.igst], &is_number/1) do
      local =
        if row.treatment == "Intrastate",
          do: Float.round(row.taxable * row.rate / 200, 2),
          else: 0.0

      inter =
        if row.treatment == "Interstate",
          do: Float.round(row.taxable * row.rate / 100, 2),
          else: 0.0

      deltas = [row.cgst - local, row.sgst - local, row.igst - inter]

      if Enum.all?(deltas, &(abs(&1) <= row.line_count * 0.005 + 0.000001)) do
        matches =
          Enum.zip(["M", "P", "S"], deltas)
          |> Enum.map_join(",", fn {col, delta} ->
            "ABS(#{col}#{excel_row}-(#{Float.round(delta, 6)}))<0.000001"
          end)

        "IF(AND(#{matches}),\"Rounding\",\"Review difference\")"
      else
        "\"Review difference\""
      end
    else
      "\"Review difference\""
    end
  end

  defp tax_rows(invoices) do
    invoices
    |> Enum.reject(&is_nil(Gstr1.filing_table(&1)))
    |> Enum.flat_map(fn invoice ->
      effect = Invoice.document_effect(invoice)

      invoice
      |> Map.get("line_items", [])
      |> List.wrap()
      |> Enum.group_by(fn line ->
        {working_rate(invoice, line), line_treatment(invoice, line)}
      end)
      |> Enum.map(fn {{rate, treatment}, lines} ->
        taxable = signed_sum_complete(lines, "taxable_value", effect)

        cgst = line_source_tax(invoice, lines, "cgst_amount", effect, "Intrastate")
        sgst = line_source_tax(invoice, lines, "sgst_amount", effect, "Intrastate")
        igst = line_source_tax(invoice, lines, "igst_amount", effect, "Interstate")

        %{
          source: source(invoice),
          source_id: invoice["id"],
          document_type: humanize(Invoice.document_type(invoice)),
          line_count: length(lines),
          document: Invoice.document_number(invoice),
          date: Invoice.document_date(invoice),
          recipient: invoice["buyer_name"],
          gstin: invoice["buyer_gstin"],
          pos: filing_pos(invoice),
          section: section(invoice),
          treatment: treatment,
          rate: rate,
          taxable: taxable,
          cgst: cgst,
          sgst: sgst,
          igst: igst
        }
      end)
    end)
  end

  defp hsn_rows(invoices) do
    invoices
    |> Enum.reject(&is_nil(Gstr1.filing_table(&1)))
    |> Enum.flat_map(fn invoice ->
      effect = Invoice.document_effect(invoice)

      invoice["line_items"]
      |> List.wrap()
      |> Enum.group_by(fn line ->
        {hsn(line), working_rate(invoice, line), uqc(line), line_treatment(invoice, line)}
      end)
      |> Enum.map(fn {{hsn, rate, uqc, line_treatment}, lines} ->
        taxable = signed_sum_complete(lines, "taxable_value", effect)

        treatment =
          if Invoice.without_payment?(invoice),
            do: "LUT/bond",
            else: line_treatment

        %{
          source_id: invoice["id"],
          document: Invoice.document_number(invoice),
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

  defp write_document_series(sheet, context, start) do
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
          Invoice.document_number(invoice) || invoice["id"],
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

    open_issues =
      context.projection
      |> Map.get(:issues, [])
      |> Enum.filter(&(&1["status"] == "open"))
      |> Enum.map(fn issue ->
        [
          if(Issues.gating?(issue), do: "Needs review", else: "Information"),
          issue_document(context, issue),
          issue["field"],
          nil,
          nil,
          issue_message(issue),
          nil,
          nil
        ]
      end)

    held_out ++ resolution_rows ++ open_issues
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
    effect = Invoice.document_effect(invoice)
    lines = List.wrap(invoice["line_items"])
    taxable = signed_sum_complete(lines, "taxable_value", effect)
    cgst = source_tax(invoice, lines, "cgst_amount", effect, "Intrastate")
    sgst = source_tax(invoice, lines, "sgst_amount", effect, "Intrastate")
    igst = source_tax(invoice, lines, "igst_amount", effect, "Interstate")
    tax = nullable_sum([cgst, sgst, igst])

    invoice_value =
      case invoice["printed_grand_total"] do
        value when is_number(value) ->
          effect * value

        _other ->
          nullable_sum([taxable, if(Invoice.tax_excluded_from_total?(invoice), do: 0, else: tax)])
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

  defp source_tax(invoice, lines, field, effect, required_treatment) do
    head = String.replace_suffix(field, "_amount", "")

    case Nila.Gst.Sales.InvoiceTaxes.printed_totals(invoice) do
      %{^head => amount} -> effect * amount
      _ -> line_source_tax(invoice, lines, field, effect, required_treatment)
    end
  end

  defp line_source_tax(invoice, lines, field, effect, required_treatment) do
    required? =
      invoice["supply_type"] not in ~w(nil_rated exempt non_gst) and
        not Invoice.tax_excluded_from_total?(invoice)

    amounts =
      Enum.map(
        lines,
        &source_invoice_tax_amount(invoice, &1, field, required?, required_treatment)
      )

    if amounts == [] or Enum.any?(amounts, &is_nil/1), do: nil, else: effect * Enum.sum(amounts)
  end

  defp source_invoice_tax_amount(invoice, line, field, required?, required_treatment) do
    case line[field] do
      value when is_number(value) ->
        value

      _missing ->
        rate = rate_for(line, field)

        cond do
          not required? -> 0.0
          is_number(rate) and rate > 0 -> nil
          rate == 0 -> 0.0
          line_rate(line) == 0 -> 0.0
          line_treatment(invoice, line) == required_treatment -> nil
          true -> 0.0
        end
    end
  end

  defp rate_for(line, "cgst_amount"), do: line["cgst_rate"]
  defp rate_for(line, "sgst_amount"), do: line["sgst_rate"]
  defp rate_for(line, "igst_amount"), do: line["igst_rate"]

  defp nullable_sum(values) do
    if Enum.all?(values, &is_number/1), do: Enum.sum(values), else: nil
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

      "nil" ->
        "Table 8 - " <>
          case invoice["supply_type"] do
            "nil_rated" -> "Nil-rated"
            "exempt" -> "Exempt"
            "non_gst" -> "Non-GST"
          end

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

      state_code(invoice["seller_gstin"]) == state_code(filing_pos(invoice)) ->
        "Intrastate"

      true ->
        "Interstate"
    end
  end

  defp filing_pos(invoice) do
    Gstr1.filing_place_of_supply(invoice)
  end

  defp source(%{"source_sheet" => sheet, "source_rows" => rows} = invoice) do
    "#{invoice["source_filename"]} / #{sheet} / rows #{Enum.join(rows, ", ")}"
  end

  defp source(invoice) do
    pages = invoice["source_pages"] |> List.wrap() |> Enum.reject(&is_nil/1) |> Enum.join(", ")
    identity = invoice["id"] || Invoice.document_number(invoice)
    Enum.reject([identity, if(pages != "", do: "p. " <> pages)], &is_nil/1) |> Enum.join(" / ")
  end

  defp hsn(line), do: line["hsn_sac"] |> display() |> String.replace(~r/\D/, "")

  defp working_rate(invoice, line) do
    if invoice["supply_type"] in ~w(nil_rated exempt non_gst), do: 0, else: line_rate(line)
  end

  defp line_rate(line) do
    cond do
      is_number(line["igst_rate"]) and line["igst_rate"] > 0 ->
        number(line["igst_rate"])

      is_number(line["cgst_rate"]) or is_number(line["sgst_rate"]) ->
        number(line["cgst_rate"]) + number(line["sgst_rate"])

      line["igst_rate"] == 0 ->
        0.0

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
