defmodule Nila.Gst.Sales.Excel.StandardSections do
  @moduledoc "Reads the GST section sheets exported by several accounting systems."
  alias Nila.Gst.Sales.Excel.{TablePlan, TableReader}

  @b2b %TablePlan{
    id: "standard_sections.b2b",
    kind: :b2b,
    fields: %{
      "buyer_gstin" => ["GSTIN/UIN of Recipient"],
      "buyer_name" => ["Receiver Name"],
      "number" => ["Invoice Number"],
      "date" => ["Invoice date"],
      "value" => ["Invoice Value"],
      "pos" => ["Place Of Supply"],
      "reverse_charge" => ["Reverse Charge"],
      "invoice_type" => ["Invoice Type"],
      "etin" => ["E-Commerce GSTIN"],
      "rate" => ["Rate"],
      "txval" => ["Taxable Value"],
      "csamt" => ["Cess Amount"]
    },
    required: ~w(buyer_gstin number date value pos rate txval)
  }
  @b2cs %TablePlan{
    id: "standard_sections.b2cs",
    kind: :b2cs,
    fields: %{
      "type" => ["Type"],
      "pos" => ["Place Of Supply"],
      "rate" => ["Rate"],
      "txval" => ["Taxable Value"],
      "csamt" => ["Cess Amount"],
      "etin" => ["E-Commerce GSTIN"]
    },
    required: ~w(type pos rate txval)
  }
  @hsn %TablePlan{
    id: "standard_sections.hsn",
    kind: :hsn,
    fields: %{
      "hsn_sc" => ["HSN"],
      "desc" => ["Description"],
      "uqc" => ["UQC"],
      "qty" => ["Total Quantity"],
      "rate" => ["Rate"],
      "txval" => ["Taxable Value"],
      "iamt" => ["Integrated Tax Amount"],
      "camt" => ["Central Tax Amount"],
      "samt" => ["State/UT Tax Amount"],
      "csamt" => ["Cess Amount"]
    },
    required: ~w(hsn_sc uqc rate txval),
    max_column: 11
  }
  @cdnr %TablePlan{
    id: "standard_sections.cdnr",
    kind: :cdnr,
    fields: %{
      "buyer_gstin" => ["GSTIN/UIN"],
      "buyer_name" => ["Receiver Name"],
      "number" => ["Note Number"],
      "date" => ["Note Date"],
      "note_type" => ["Note Type"],
      "pos" => ["Place Of Supply"],
      "reverse_charge" => ["Reverse Charge"],
      "invoice_type" => ["Note Supply Type"],
      "value" => ["Note Value"],
      "rate" => ["Rate"],
      "txval" => ["Taxable Value"],
      "csamt" => ["Cess Amount"]
    },
    required: ~w(buyer_gstin number date note_type pos value rate txval)
  }
  @cdnur %TablePlan{
    id: "standard_sections.cdnur",
    kind: :cdnur,
    fields: %{
      "type" => ["UR Type"],
      "number" => ["Note Number"],
      "date" => ["Note Date"],
      "note_type" => ["Note Type"],
      "pos" => ["Place Of Supply"],
      "value" => ["Note Value"],
      "unregistered_supply_type" => ["Applicable % of Tax Rate"],
      "rate" => ["Rate"],
      "txval" => ["Taxable Value"],
      "csamt" => ["Cess Amount"]
    },
    required: ~w(type number date note_type pos value rate txval)
  }

  @known [
    "b2b",
    "b2b,sez,de",
    "b2cl",
    "b2cs",
    "cdnr",
    "cdnur",
    "exp",
    "at",
    "atadj",
    "exemp",
    "hsn(b2b)",
    "hsn(b2c)",
    "docs"
  ]
  @columns %{
    "doc_issue" => %{
      "nature" => "A",
      "from" => "B",
      "to" => "C",
      "totnum" => "D",
      "cancel" => "E"
    },
    "nil" => %{"description" => "A", "nil_amt" => "B", "expt_amt" => "C", "ngsup_amt" => "D"}
  }

  def matches?(%{sheets: sheets}) do
    Enum.any?(sheets, fn sheet ->
      sheet.name in ["B2B", "b2b", "b2b,sez,de"] and
        TableReader.matches?(sheet, @b2b)
    end)
  end

  def parse(workbook, client, period) do
    with false <- Enum.any?(workbook.sheets, & &1.hidden?),
         :ok <- check_identity(workbook.sheets, client, period),
         {:ok, rows} <- read_sheets(workbook.sheets, client, period) do
      if rows == [],
        do: {:error, "This report contains no entries."},
        else:
          {:ok, %{"format" => "standard_gstr1_sections", "format_version" => 1, "rows" => rows}}
    else
      true -> {:error, "Hidden report sheets are not supported."}
      error -> error
    end
  catch
    {:report_error, message} -> {:error, message}
  end

  defp check_identity(sheets, client, period) do
    if not Regex.match?(~r/\A\d{4}-(0[1-9]|1[0-2])\z/, period),
      do: fail("Report", 1, "Select a GST month.")

    overview = Enum.find(sheets, &(&1.name == "GSTR1 Report"))

    if overview do
      gstin =
        overview.rows |> Enum.find(&(&1.cells["A"] == "1. GSTIN")) |> then(&(&1 && &1.cells["B"]))

      if gstin && gstin != client.gstin,
        do: fail(overview.name, 3, "Supplier GSTIN does not match this client.")

      printed_period =
        overview.rows |> Enum.find(&(&1.cells["A"] == "Period")) |> then(&(&1 && &1.cells["B"]))

      {:ok, month} = Date.from_iso8601(period <> "-01")
      month_label = Calendar.strftime(month, "%B %Y")

      if printed_period && printed_period != "#{month_label} - #{month_label}",
        do: fail(overview.name, 1, "Report period does not match the selected GST month.")
    end

    :ok
  end

  defp read_sheets(sheets, client, period) do
    rows =
      Enum.flat_map(sheets, fn sheet ->
        case String.downcase(sheet.name) do
          name when name in ["b2b", "b2b,sez,de"] -> read_b2b(sheet, client, period)
          "b2cs" -> read_b2cs(sheet, client, period)
          "hsn(b2b)" -> read_hsn(sheet, client, period, "hsn_b2b")
          "hsn(b2c)" -> read_hsn(sheet, client, period, "hsn_b2c")
          "hsn" -> read_hsn(sheet, client, period, hsn_section(sheet))
          "cdnr" -> read_cdnr(sheet, client, period)
          "cdnur" -> read_cdnur(sheet, client, period)
          "docs" -> read_docs(sheet, client, period)
          "exemp" -> read_exempt(sheet, client, period)
          "gstr1 report" -> []
          "gstr1" -> []
          "itemsummary" -> []
          name when name in @known -> require_empty(sheet)
          _ -> fail(sheet.name, 1, "Unrecognized sheet; nothing was imported.")
        end
      end)

    {:ok, rows}
  end

  defp read_b2b(sheet, client, period) do
    table = TableReader.read!(sheet, @b2b)

    rows =
      Enum.map(table.rows, fn %{source: row, values: c} ->
        rate = cell_amount(c, table, "rate", sheet, row)
        taxable = cell_amount(c, table, "txval", sheet, row)
        value = cell_amount(c, table, "value", sheet, row)
        pos = state(c["pos"], sheet, row)

        if blank?(c["buyer_gstin"]) or blank?(c["number"]) or is_nil(value) or
             is_nil(rate) or is_nil(taxable),
           do:
             fail(
               sheet.name,
               row.row,
               "Invoice GSTIN, number, value, rate or taxable value is missing."
             )

        date = document_date(c["date"], sheet, row, period)

        values =
          common(client, period)
          |> Map.merge(%{
            "buyer_gstin" => str(c["buyer_gstin"]),
            "buyer_name" => str(c["buyer_name"]),
            "number" => str(c["number"]),
            "date" => date,
            "value" => value,
            "pos" => pos,
            "reverse_charge" => str(c["reverse_charge"]),
            "invoice_type" => invoice_type(c["invoice_type"]),
            "etin" => str(c["etin"]),
            "rate" => rate,
            "txval" => taxable,
            "csamt" => cell_amount(c, table, "csamt", sheet, row) || 0.0
          })
          |> put_tax(taxable, rate, pos, client)

        evidence(sheet, table, row, "B2B", "b2b", values)
      end)

    TableReader.require_agreement!(
      rows,
      ~w(section number),
      ~w(buyer_gstin date value buyer_name pos reverse_charge invoice_type),
      sheet.name
    )

    rows
  end

  defp read_b2cs(sheet, client, period) do
    table = TableReader.read!(sheet, @b2cs)

    Enum.map(table.rows, fn %{source: row, values: c} ->
      rate = cell_amount(c, table, "rate", sheet, row)
      taxable = cell_amount(c, table, "txval", sheet, row)
      pos = state(c["pos"], sheet, row)

      if is_nil(rate) or is_nil(taxable),
        do: fail(sheet.name, row.row, "Rate or taxable value is missing.")

      values =
        common(client, period)
        |> Map.merge(%{
          "type" => str(c["type"]),
          "pos" => pos,
          "supply" => if(pos == String.slice(client.gstin, 0, 2), do: "INTRA", else: "INTER"),
          "rate" => rate,
          "txval" => taxable,
          "csamt" => cell_amount(c, table, "csamt", sheet, row) || 0.0,
          "etin" => str(c["etin"])
        })
        |> put_tax(taxable, rate, pos, client)

      evidence(sheet, table, row, "B2CS", "b2cs", values)
    end)
  end

  defp read_hsn(sheet, client, period, section) do
    table = sheet |> TableReader.read!(@hsn) |> legacy_hsn_columns()

    Enum.map(table.rows, fn %{source: row, values: c} ->
      values =
        common(client, period)
        |> Map.merge(%{
          "hsn_sc" => str(c["hsn_sc"]),
          "desc" => str(c["desc"]),
          "uqc" => uqc(c["uqc"]),
          "qty" => cell_amount(c, table, "qty", sheet, row),
          "rate" => cell_amount(c, table, "rate", sheet, row),
          "txval" => cell_amount(c, table, "txval", sheet, row),
          "iamt" => cell_amount(c, table, "iamt", sheet, row),
          "camt" => cell_amount(c, table, "camt", sheet, row),
          "samt" => cell_amount(c, table, "samt", sheet, row),
          "csamt" => cell_amount(c, table, "csamt", sheet, row)
        })

      evidence(sheet, table, row, String.upcase(section), section, values)
    end)
  end

  defp legacy_hsn_columns(%{columns: columns} = table) do
    if columns["hsn_sc"] == "A" and columns["uqc"] == "C" and
         columns["rate"] == "F" and columns["txval"] == "G" do
      defaults = %{
        "desc" => "B",
        "qty" => "D",
        "iamt" => "H",
        "camt" => "I",
        "samt" => "J",
        "csamt" => "K"
      }

      columns =
        Map.merge(columns, defaults, fn _, actual, fallback -> actual || fallback end)

      rows =
        Enum.map(table.rows, fn entry ->
          %{
            entry
            | values:
                Map.new(columns, fn {field, column} -> {field, entry.source.cells[column]} end)
          }
        end)

      %{table | columns: columns, rows: rows}
    else
      table
    end
  end

  defp read_cdnr(sheet, client, period) do
    table = TableReader.read!(sheet, @cdnr)

    rows =
      Enum.map(table.rows, fn %{source: row, values: c} ->
        if blank?(c["buyer_gstin"]),
          do: fail(sheet.name, row.row, "Buyer GSTIN is missing from the registered note.")

        values =
          note_values(c, table, sheet, row, client, period)
          |> Map.merge(%{
            "buyer_gstin" => str(c["buyer_gstin"]),
            "buyer_name" => str(c["buyer_name"]),
            "invoice_type" => invoice_type(c["invoice_type"])
          })

        evidence(sheet, table, row, "CDNR", "cdnr", values)
      end)

    check_note_agreement!(rows, sheet.name)
    rows
  end

  defp read_cdnur(sheet, client, period) do
    table = TableReader.read!(sheet, @cdnur)

    rows =
      Enum.map(table.rows, fn %{source: row, values: c} ->
        values = note_values(c, table, sheet, row, client, period)
        ur_type = str(c["type"])

        if Regex.match?(~r/\A\d{2}[A-Z0-9]{13}\z/, ur_type || "") do
          values =
            Map.merge(values, %{
              "buyer_gstin" => ur_type,
              "invoice_type" => invoice_type(c["unregistered_supply_type"]),
              "source_ur_type" => ur_type
            })

          evidence(sheet, table, row, "CDNR", "cdnr", values)
        else
          values = Map.put(values, "type", ur_type)
          evidence(sheet, table, row, "CDNUR", "cdnur", values)
        end
      end)

    check_note_agreement!(rows, sheet.name)
    rows
  end

  defp note_values(c, table, sheet, row, client, period) do
    value = cell_amount(c, table, "value", sheet, row)
    rate = cell_amount(c, table, "rate", sheet, row)
    taxable = cell_amount(c, table, "txval", sheet, row)
    pos = state(c["pos"], sheet, row)

    if blank?(c["number"]) or is_nil(value) or is_nil(rate) or is_nil(taxable),
      do: fail(sheet.name, row.row, "Note number, value, rate or taxable value is missing.")

    common(client, period)
    |> Map.merge(%{
      "number" => str(c["number"]),
      "date" => document_date(c["date"], sheet, row, period),
      "note_type" => str(c["note_type"]),
      "value" => value,
      "pos" => pos,
      "reverse_charge" => str(c["reverse_charge"]),
      "rate" => rate,
      "txval" => taxable,
      "csamt" => cell_amount(c, table, "csamt", sheet, row) || 0.0
    })
    |> put_tax(taxable, rate, pos, client)
  end

  defp check_note_agreement!(rows, sheet_name) do
    TableReader.require_agreement!(
      rows,
      ~w(section number),
      ~w(buyer_gstin date value pos note_type type invoice_type),
      sheet_name
    )
  end

  defp hsn_section(sheet) do
    name = String.downcase(sheet[:source_filename] || "")

    cond do
      String.contains?(name, "b2b") -> "hsn_b2b"
      String.contains?(name, "b2c") -> "hsn_b2c"
      true -> fail(sheet.name, 1, "HSN sheet needs a B2B or B2C source filename.")
    end
  end

  defp read_docs(sheet, client, period) do
    {header, rows} =
      details(sheet, %{
        "A" => "Nature of Document",
        "B" => "Sr. No. From",
        "C" => "Sr. No. To",
        "D" => "Total Number",
        "E" => "Cancelled"
      })

    Enum.map(rows, fn row ->
      c = row.cells
      total = amount(c["D"], sheet, row, "D")
      cancelled = amount(c["E"], sheet, row, "E")

      values =
        common(client, period)
        |> Map.merge(%{
          "nature" => str(c["A"]),
          "from" => str(c["B"]),
          "to" => str(c["C"]),
          "totnum" => total,
          "cancel" => cancelled,
          "net_issue" => if(is_number(total) and is_number(cancelled), do: total - cancelled),
          "doc_num" =>
            if(c["A"] in ["Invoice for outward supply", "Invoices for outward supply"], do: 1)
        })

      evidence(sheet, header, row, "Docs", "doc_issue", values)
    end)
  end

  defp read_exempt(sheet, client, period) do
    {header, rows} =
      details(sheet, %{
        "A" => "Description",
        "B" => "Nil Rated Supplies",
        "D" => "Non-GST Supplies"
      })

    Enum.map(rows, fn row ->
      c = row.cells

      values =
        common(client, period)
        |> Map.merge(%{
          "description" => str(c["A"]),
          "nil_amt" => amount(c["B"], sheet, row, "B") || 0.0,
          "expt_amt" => amount(c["C"], sheet, row, "C") || 0.0,
          "ngsup_amt" => amount(c["D"], sheet, row, "D") || 0.0
        })

      evidence(sheet, header, row, "exemp", "nil", values)
    end)
  end

  defp require_empty(sheet) do
    header =
      Enum.find(sheet.rows, fn row ->
        Enum.any?(Map.values(row.cells), fn value ->
          value in ["Invoice Number", "Note Number", "Rate", "Taxable Value"]
        end)
      end)

    first_data = Enum.find(sheet.rows, &(&1.row > if(header, do: header.row, else: 4)))

    if first_data,
      do:
        fail(
          sheet.name,
          first_data.row,
          "This section has entries that the reader cannot import yet."
        )

    []
  end

  defp details(sheet, expected) do
    header = Enum.find(sheet.rows, &headers?(&1.cells, expected))
    if is_nil(header), do: fail(sheet.name, 1, "Section columns are missing.")
    {header, Enum.filter(sheet.rows, &(&1.row > header.row))}
  end

  defp headers?(cells, expected),
    do: Enum.all?(expected, fn {column, label} -> str(cells[column]) == label end)

  defp common(client, period),
    do: %{
      "seller_gstin" => client.gstin,
      "period" => String.slice(period, 5, 2) <> String.slice(period, 0, 4)
    }

  defp evidence(
         sheet,
         %{header: header, columns: columns} = table,
         row,
         canonical,
         section,
         values
       ),
       do: %{
         "sheet" => sheet.name,
         "source_filename" => sheet[:source_filename],
         "table_plan" => table.plan,
         "granularity" =>
           if(canonical in ~w(B2B B2CL CDNR CDNUR),
             do: "invoice_rate_component",
             else: "supplied_summary"
           ),
         "return_sheet" => canonical,
         "section" => section,
         "row" => row.row,
         "values" => values,
         "headers" => header.cells,
         "columns" => columns,
         "cells" =>
           Map.new(row.cells, fn {column, value} ->
             {column, if(is_atom(value), do: to_string(value), else: value)}
           end)
       }

  defp evidence(sheet, header, row, canonical, section, values),
    do: %{
      "sheet" => sheet.name,
      "source_filename" => sheet[:source_filename],
      "table_plan" => %{"id" => "standard_sections.#{section}", "version" => 1},
      "granularity" => "supplied_summary",
      "return_sheet" => canonical,
      "section" => section,
      "row" => row.row,
      "values" => values,
      "headers" => header.cells,
      "columns" => @columns[section],
      "cells" =>
        Map.new(row.cells, fn {column, value} ->
          {column, if(is_atom(value), do: to_string(value), else: value)}
        end)
    }

  defp put_tax(values, taxable, rate, pos, client) do
    tax = Float.round(taxable * rate / 100, 2)

    if pos == String.slice(client.gstin, 0, 2) do
      half = Float.round(taxable * rate / 200, 2)
      Map.merge(values, %{"iamt" => 0.0, "camt" => half, "samt" => half})
    else
      Map.merge(values, %{"iamt" => tax, "camt" => 0.0, "samt" => 0.0})
    end
  end

  defp invoice_type(nil), do: nil
  defp invoice_type("Regular B2B"), do: "R"
  defp invoice_type(other), do: str(other)

  defp uqc(value) do
    case str(value) do
      nil -> nil
      code -> code |> String.split("-", parts: 2) |> hd()
    end
  end

  defp state(value, sheet, row) do
    case Regex.run(~r/\A(\d{2})(?:\s*-\s*|\z)/, str(value) || "") do
      [_, code] -> code
      _ -> fail(sheet.name, row.row, "Place of supply is missing or invalid.")
    end
  end

  defp document_date(value, sheet, row, period) do
    case Nila.Gst.Dates.parse_date(str(value)) do
      %Date{} = date ->
        iso = Date.to_iso8601(date)

        if String.starts_with?(iso, period),
          do: iso,
          else: fail(sheet.name, row.row, "Invoice is outside the selected GST month.")

      _ ->
        fail(sheet.name, row.row, "Invoice date is invalid.")
    end
  end

  defp amount(value, _, _, _) when value in [nil, ""], do: nil

  defp amount(value, sheet, row, column) do
    if value in [:formula, :invalid_cell],
      do: fail(sheet.name, row.row, "#{column} contains a formula or cell error.")

    case Float.parse(String.replace(to_string(value), ",", "")) do
      {number, ""} when abs(number) < 1.0e12 -> number
      _ -> fail(sheet.name, row.row, "#{column} is not a valid amount.")
    end
  end

  defp cell_amount(values, table, field, sheet, row),
    do: amount(values[field], sheet, row, table.columns[field] || field)

  defp blank?(value), do: value in [nil, ""]
  defp str(value) when value in [nil, ""], do: nil
  defp str(value) when is_atom(value), do: nil
  defp str(value), do: value |> to_string() |> String.trim()
  defp fail(sheet, row, message), do: throw({:report_error, "#{sheet}, row #{row}: #{message}"})
end
