defmodule Nila.Gst.Sales.Workings.Xlsx do
  @moduledoc """
  Builds the accountant-facing sales working for one GST period.

  The workbook is a projection of the effective sales month. It does not
  calculate a second version of GSTR-1. Formula cells expose the arithmetic controls a reviewer expects
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
          sales_register_sheet(context),
          tax_breakdown_sheet(context),
          hsn_working_sheet(context)
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
      tax_rows: tax_rows,
      hsn_rows: hsn_rows,
      tax_last_row: max(5, 4 + length(tax_rows)),
      hsn_last_row: max(5, 4 + length(hsn_rows))
    }
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
    |> sales_totals(length(rows))
    |> population_counts(context, length(rows) + 8)
    |> set_widths([18, 13, 34, 22, 10, 14, 16, 14, 14, 14, 16, 14, 14, 22, 16, 28])
    |> fit_rows(4, rows, [18, 13, 34, 22, 10, 14, 16, 14, 14, 14, 16, 14, 14, 22, 16, 28])
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
      XlsxWriter.new_sheet("Tax Working")
      |> title(context, "Tax working")
      |> write_headers(3, headers)
      |> write_rows(4, rows)
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
    |> fit_rows(4, rows, [
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
      16,
      28
    ])
    |> XlsxWriter.write(
      2,
      0,
      "Source = reviewed invoice amounts. Calculated = taxable value x tax rate.",
      format: @subtitle_format
    )
    |> tax_summaries(context)
  end

  defp sales_totals(sheet, count) do
    last = 4 + count
    sheet = XlsxWriter.write(sheet, last + 1, 0, "Visible total", format: @section_format)

    Enum.reduce(6..10, sheet, fn col, sheet ->
      letter = <<?A + col>>

      write_cell(
        sheet,
        last + 1,
        col,
        {:formula, "=SUBTOTAL(109,#{letter}5:#{letter}#{last})", :money}
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

  defp tax_summaries(sheet, context) do
    last = context.tax_last_row
    start = last + 3

    groups =
      context.tax_rows
      |> Enum.map(&{&1.section, &1.treatment, &1.rate})
      |> Enum.uniq()
      |> Enum.sort()

    sheet =
      sheet
      |> XlsxWriter.write(start - 1, 0, "Rate-wise sales", format: @section_format)
      |> write_headers(start, [
        "GSTR-1 table",
        "Supply",
        "Rate",
        "Taxable value",
        "Source CGST",
        "Source SGST",
        "Source IGST"
      ])

    sheet =
      groups
      |> Enum.with_index(start + 1)
      |> Enum.reduce(sheet, fn {{section, treatment, rate}, row}, sheet ->
        excel = row + 1

        sums =
          for col <- ~w(J K N Q),
              do:
                {:formula,
                 "=SUMIFS($#{col}$5:$#{col}$#{last},$G$5:$G$#{last},A#{excel},$H$5:$H$#{last},B#{excel},$I$5:$I$#{last},C#{excel})",
                 :money}

        write_row(
          sheet,
          row,
          [section, treatment, {:percent, nullable_divide(rate, 100)}] ++ sums
        )
      end)

    write_document_series(sheet, context, start + length(groups) + 4)
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
          {:formula, "=IF(G#{excel_row}=\"Intrastate\",ROUND(H#{excel_row}*F#{excel_row}/2,2),0)",
           :money},
          {:formula, "=IF(G#{excel_row}=\"Intrastate\",ROUND(H#{excel_row}*F#{excel_row}/2,2),0)",
           :money},
          {:formula, "=IF(G#{excel_row}=\"Interstate\",ROUND(H#{excel_row}*F#{excel_row},2),0)",
           :money},
          {:formula, "=SUM(I#{excel_row}:K#{excel_row})", :money}
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
      |> table_layout(3, max(4, 3 + length(detail_rows)), length(detail_headers) - 1)
      |> XlsxWriter.write(summary_header_row - 1, 0, "HSN summary", format: @section_format)
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
                 "=SUMIFS($#{col}$5:$#{col}$#{context.hsn_last_row},$B$5:$B$#{context.hsn_last_row},B#{excel},$F$5:$F$#{context.hsn_last_row},F#{excel},$D$5:$D$#{context.hsn_last_row},D#{excel})",
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
          fit_rows(sheet, zero_row, [[nil, nil, description]], [18, 13, 34]),
          zero_row,
          [nil, hsn, description, uqc, hd(formulas), {:percent, nullable_divide(rate, 100)}, nil] ++
            tl(formulas) ++ [{:formula, "=SUM(I#{excel}:K#{excel})", :money}]
        )
      end)

    sheet
    |> set_widths([18, 13, 34, 10, 12, 10, 14, 16, 14, 14, 14, 14])
    |> fit_rows(4, detail_rows, [18, 13, 34, 10, 12, 10, 14, 16, 14, 14, 14, 14])
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
    |> fit_rows(4, rows, [14, 24, 24, 24, 24, 48, 22, 20])
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

  defp fit_rows(sheet, first_row, rows, widths) do
    rows
    |> Enum.with_index(first_row)
    |> Enum.reduce(sheet, fn {cells, row}, sheet ->
      lines =
        cells
        |> Enum.zip(widths)
        |> Enum.map(fn
          {text, width} when is_binary(text) ->
            capacity = max(1, trunc(width * 0.9))

            text
            |> String.split("\n")
            |> Enum.map(fn paragraph ->
              paragraph
              |> String.split()
              |> Enum.reduce({1, 0}, fn word, {lines, used} ->
                length = String.length(word)

                if used > 0 and used + 1 + length > capacity,
                  do: {lines + max(1, ceil(length / capacity)), length},
                  else: {lines, used + if(used > 0, do: 1, else: 0) + length}
              end)
              |> elem(0)
            end)
            |> Enum.sum()

          _cell ->
            1
        end)
        |> Enum.max(fn -> 1 end)

      XlsxWriter.set_row_height(sheet, row, max(20, lines * 15))
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

        non_taxable? = invoice["supply_type"] in ~w(nil_rated exempt non_gst)

        cgst =
          source_tax(lines, "cgst_amount", effect, not non_taxable? and treatment == "Intrastate")

        sgst =
          source_tax(lines, "sgst_amount", effect, not non_taxable? and treatment == "Intrastate")

        igst =
          source_tax(lines, "igst_amount", effect, not non_taxable? and treatment == "Interstate")

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
          igst: igst,
          tax: number(cgst) + number(sgst) + number(igst)
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
        taxable = effect * Enum.sum(Enum.map(lines, &number(&1["taxable_value"])))

        treatment =
          if Invoice.without_payment?(invoice),
            do: "LUT/bond",
            else: line_treatment

        %{
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

  defp source_tax(lines, field, effect, required?) do
    if required? or Enum.any?(lines, &(not is_nil(&1[field]))),
      do: signed_sum_complete(lines, field, effect),
      else: 0.0
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
