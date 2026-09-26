defmodule Nila.Gst.Sales.Excel.ReturnReport do
  @moduledoc "Reads the section-based GSTR-1 report export, retaining each source row."
  alias Nila.Gst.Extraction.Sales.Normalizer

  @sections ~w(B2B B2CL B2CS CDNR CDNUR HSNB2B HSNB2CS Docs)
  @summary_sections %{
    "B2CS" => "b2cs",
    "HSNB2B" => "hsn_b2b",
    "HSNB2CS" => "hsn_b2c",
    "Docs" => "doc_issue"
  }
  @transaction_sections ~w(B2B B2CL CDNR CDNUR)
  @common %{
    "seller_gstin" => ["GSTIN/UIN of Supplier"],
    "period" => ["Return Period"],
    "buyer_gstin" => ["GSTIN/UIN of Recipient"],
    "buyer_name" => ["Customer Name"],
    "number" => ["Invoice number", "Credit note/debit note / Refund Voucher Number"],
    "date" => ["Invoice Date", "Credit Note/Debit Note/ Refund Voucher date"],
    "value" => ["Invoice Value", "Total Note Value", "Total Value"],
    "pos" => ["Place of Supply(POS)"],
    "reverse_charge" => ["Reveress Charge", "Reverse Charge"],
    "invoice_type" => ["Invoice Type"],
    "note_type" => ["Credit/debit note type/ Refund Voucher"],
    "rate" => ["Rate of GST", "Rate"],
    "txval" => ["Taxable Value"],
    "iamt" => ["IGST Amount", "Total IGST Amount"],
    "camt" => ["CGST Amount", "Total CGST Amount"],
    "samt" => ["SGST Amount", "Total SGST / UTGST Amount"],
    "csamt" => ["Cess Amount"],
    "type" => ["Type", "Type of Customer"],
    "supply" => ["Inter State/ Intra State"],
    "etin" => ["E-Commerce GSTIN", "GSTIN of E-Commerse Operator"],
    "tcs" => ["TCS Tax Amount"],
    "hsn_sc" => ["HSN"],
    "desc" => ["Description"],
    "uqc" => ["UQC"],
    "qty" => ["Total Quantity"],
    "nature" => ["Nature of document"],
    "from" => ["From serial number"],
    "to" => ["To serial number"],
    "totnum" => ["Total Number"],
    "cancel" => ["Cancelled"],
    "net_issue" => ["Net issued"]
  }
  @numbers ~w(value rate txval iamt camt samt csamt tcs qty totnum cancel net_issue)

  def parse(workbook, client, period) do
    with true <- workbook.sheets != [] and Enum.all?(workbook.sheets, &(&1.name in @sections)),
         false <- Enum.any?(workbook.sheets, & &1.hidden?) do
      rows = Enum.flat_map(workbook.sheets, &read_sheet/1)
      expected_period = String.slice(period, 5, 2) <> String.slice(period, 0, 4)

      cond do
        rows == [] ->
          {:error, "This report contains no entries."}

        Enum.any?(rows, &(&1["values"]["seller_gstin"] != client.gstin)) ->
          {:error,
           "The report's supplier GSTIN does not match this client. Nothing was imported."}

        Enum.any?(rows, &(&1["values"]["period"] != expected_period)) ->
          {:error,
           "The report contains entries outside the selected GST month. Nothing was imported."}

        true ->
          {:ok, %{"format" => "gstr1_sections_v1", "rows" => rows}}
      end
    else
      _ ->
        {:error,
         "This workbook format is not supported yet. Choose the section-based GSTR-1 report."}
    end
  catch
    {:report_error, message} -> {:error, message}
  end

  def invoices(report, client) do
    report["rows"]
    |> Enum.filter(&(String.upcase(&1["section"] || "") in @transaction_sections))
    |> Enum.group_by(
      &{&1["source_filename"], &1["sheet"], String.upcase(&1["section"]),
       &1["values"]["buyer_gstin"], &1["values"]["number"], &1["values"]["date"]}
    )
    |> Enum.sort_by(fn {_, rows} -> {hd(rows)["sheet"], hd(rows)["row"]} end)
    |> Enum.map(fn {{_, _, section, _, _, _}, rows} -> invoice(section, rows, client) end)
    |> collapse_registered_note_copies()
  end

  # Some exports repeat a registered note in both CDNR and CDNUR. Keep one
  # financial document, with both physical source rows attached to it.
  defp collapse_registered_note_copies(invoices) do
    invoices
    |> Enum.with_index()
    |> Enum.group_by(fn {invoice, index} ->
      if invoice["return_report_section"] == "CDNR" and
           invoice["source_sheet"] in ["CDNR", "CDNUR"],
         do: {:note, note_fingerprint(invoice)},
         else: {:other, index}
    end)
    |> Enum.flat_map(fn {_, group} ->
      Enum.reduce(group, [], fn {invoice, index}, kept ->
        case Enum.find_index(kept, fn {other, _} -> same_note_copy?(other, invoice) end) do
          nil ->
            [{invoice, index} | kept]

          position ->
            List.update_at(kept, position, fn {other, first_index} ->
              {merge_note_sources(other, invoice), first_index}
            end)
        end
      end)
    end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp note_fingerprint(invoice) do
    {
      Map.take(
        invoice,
        ~w(seller_gstin buyer_gstin invoice_number invoice_date document_type document_status supply_type recipient_registration place_of_supply printed_grand_total original_sale_category)
      ),
      invoice["return_report_values"]
      |> Enum.map(&Map.drop(&1, ~w(buyer_name reverse_charge source_ur_type)))
      |> Enum.sort()
    }
  end

  defp same_note_copy?(first, second) do
    first["source_filename"] != second["source_filename"] and
      first["source_sheet"] != second["source_sheet"] and
      compatible_optional?(first["buyer_name"], second["buyer_name"]) and
      compatible_optional?(first["reverse_charge"], second["reverse_charge"])
  end

  defp compatible_optional?(first, second),
    do: first in [nil, ""] or second in [nil, ""] or first == second

  defp merge_note_sources(first, second) do
    {primary, other} =
      if first["source_sheet"] == "CDNR", do: {first, second}, else: {second, first}

    primary
    |> Map.put("source_refs", primary["source_refs"] ++ other["source_refs"])
    |> Map.put("source_rows", primary["source_rows"] ++ other["source_rows"])
    |> Map.put(
      "return_report_values",
      primary["return_report_values"] ++ other["return_report_values"]
    )
    |> Map.put("buyer_name", known_value(primary["buyer_name"], other["buyer_name"]))
    |> Map.put(
      "reverse_charge",
      known_value(primary["reverse_charge"], other["reverse_charge"])
    )
  end

  defp known_value(value, fallback) when value in [nil, ""], do: fallback
  defp known_value(value, _fallback), do: value

  def summaries(report),
    do:
      Enum.reject(report["rows"], &(String.upcase(&1["section"] || "") in @transaction_sections))

  defp read_sheet(sheet) do
    header =
      Enum.find(Enum.take(sheet.rows, 30), fn row ->
        names = Enum.map(Map.values(row.cells), &header_key/1)
        "gstinuinofsupplier" in names and "returnperiod" in names
      end)

    if is_nil(header), do: fail(sheet.name, 1, "Column headers are missing.")

    aliases =
      if sheet.name in ~w(CDNR CDNUR),
        do:
          @common
          |> Map.put("number", ["Credit note/debit note / Refund Voucher Number"])
          |> Map.put("date", ["Credit Note/Debit Note/ Refund Voucher date"]),
        else: @common

    mapping =
      Map.new(aliases, fn {field, names} ->
        names = Enum.map(names, &header_key/1)
        matches = Enum.filter(header.cells, fn {_, text} -> header_key(text) in names end)
        if length(matches) > 1, do: fail(sheet.name, 1, "Ambiguous #{field} columns.")

        {field,
         case matches do
           [{column, _}] -> column
           _ -> nil
         end}
      end)

    required =
      case sheet.name do
        "Docs" ->
          ~w(seller_gstin period nature from to totnum cancel net_issue)

        section when section in ~w(HSNB2B HSNB2CS) ->
          ~w(seller_gstin period hsn_sc uqc qty rate txval iamt camt samt csamt)

        "B2CS" ->
          ~w(seller_gstin period type pos rate txval iamt camt samt csamt)

        _ ->
          ~w(seller_gstin period number date value rate txval iamt csamt)
      end

    for field <- required,
        is_nil(mapping[field]),
        do: fail(sheet.name, 1, "Missing #{field} column.")

    for row <- sheet.rows, row.row > header.row do
      values =
        Map.new(mapping, fn {field, column} ->
          raw = Map.get(row.cells, column)

          if raw in [:formula, :invalid_cell],
            do:
              fail(
                sheet.name,
                row.row,
                "#{column} contains a formula or cell error. Supply values."
              )

          value =
            if field in @numbers, do: number(raw, sheet.name, row.row, column), else: blank(raw)

          {field, value}
        end)

      if sheet.name in @transaction_sections and
           (is_nil(values["number"]) or is_nil(values["date"])),
         do: fail(sheet.name, row.row, "Document number or date is missing.")

      values =
        if values["date"],
          do: Map.update!(values, "date", &date(&1, sheet.name, row.row)),
          else: values

      values =
        if sheet.name == "Docs",
          do: Map.put(values, "doc_num", document_kind(values["nature"])),
          else: values

      %{
        "sheet" => sheet.name,
        "section" => @summary_sections[sheet.name] || String.downcase(sheet.name),
        "row" => row.row,
        "values" => values,
        "headers" => header.cells,
        "columns" => mapping,
        "cells" =>
          Map.new(row.cells, fn {key, value} ->
            {key, if(is_atom(value), do: to_string(value), else: value)}
          end)
      }
    end
  end

  defp invoice(section, rows, _client) do
    first = hd(rows)
    v = first["values"]
    note? = section in ~w(CDNR CDNUR)

    lines =
      Enum.map(rows, fn row ->
        value = row["values"]
        rate = value["rate"]
        interstate? = (value["iamt"] || 0) != 0

        %{
          "description" => "#{section} rate row #{row["row"]}",
          "printed_taxable_value" => value["txval"],
          "cgst_amount" => value["camt"],
          "sgst_amount" => value["samt"],
          "igst_amount" => value["iamt"],
          "cgst_rate" => if(!interstate? and is_number(rate), do: rate / 2),
          "sgst_rate" => if(!interstate? and is_number(rate), do: rate / 2),
          "igst_rate" => if(interstate?, do: rate)
        }
      end)

    data = %{
      "document_type" => if(note?, do: note_type(v["note_type"]), else: "invoice"),
      "document_status" => "active",
      "supply_type" => "taxable",
      "reverse_charge" =>
        case v["reverse_charge"] do
          "Y" -> true
          "N" -> false
          _ -> nil
        end,
      "invoice_number" => v["number"],
      "invoice_date" => v["date"],
      "seller" => %{"gstin" => v["seller_gstin"]},
      "buyer" => %{"name" => v["buyer_name"], "gstin" => v["buyer_gstin"]},
      "recipient_registration" =>
        if(section in ~w(B2B CDNR), do: "registered", else: "unregistered"),
      "place_of_supply" => v["pos"],
      "printed_grand_total" => v["value"],
      "original_sale_category" => if(section == "CDNUR", do: String.downcase(v["type"] || "")),
      "line_items" => lines
    }

    Normalizer.normalize(%{"data" => data})
    |> Map.merge(%{
      "id" => invoice_source_id(section, first),
      "source_filename" => first["source_filename"],
      "source_sheet" => first["sheet"],
      "source_rows" => Enum.map(rows, & &1["row"]),
      "source_refs" => Enum.map(rows, &Map.take(&1, ~w(source_filename sheet row))),
      "source_granularity" => "invoice_rate_components",
      "source_pages" => [],
      "return_report_section" => section,
      "return_report_values" => Enum.map(rows, & &1["values"])
    })
  end

  defp invoice_source_id(section, %{"source_filename" => filename} = row)
       when is_binary(filename) do
    key =
      :crypto.hash(:sha256, :erlang.term_to_binary({filename, row["sheet"]}))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "report_#{key}_#{section}_#{row["row"]}"
  end

  defp invoice_source_id(section, row), do: "report_#{section}_#{row["row"]}"

  defp note_type("C"), do: "credit_note"
  defp note_type("D"), do: "debit_note"
  defp note_type(_), do: "unknown"

  defp document_kind(label)
       when label in ["Invoice for outward supply", "Invoices for outward supply"], do: 1

  defp document_kind(label) when label in ["Sales Return Credit Note", "Credit Note"], do: 5
  defp document_kind("Debit Note"), do: 4
  defp document_kind(_), do: nil

  defp header_key(value) when is_binary(value),
    do: value |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  defp header_key(_), do: ""
  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value |> to_string() |> String.trim()
  defp number(value, _, _, _) when value in [nil, ""], do: nil

  defp number(value, sheet, row, column) do
    case Float.parse(String.replace(to_string(value), ",", "")) do
      {number, ""} when abs(number) < 1.0e12 -> number
      _ -> fail(sheet, row, "#{column} is not a valid amount.")
    end
  end

  defp date(text, sheet, row) do
    case Nila.Gst.Dates.parse_date(text) do
      %Date{} = date -> Date.to_iso8601(date)
      _ -> fail(sheet, row, "Document date is invalid.")
    end
  end

  defp fail(sheet, row, message), do: throw({:report_error, "#{sheet}, row #{row}: #{message}"})
end
