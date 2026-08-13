defmodule Nila.Gst.Filing.WinmanGstr1.Package do
  @moduledoc false

  @template_path "priv/templates/winman/gstr1-9.5.6-fy2026-27.xlsm"
  @template_sha256 "c6ff1f1cae5fe457ed913bd1b73a26f7c10a399ff27bd61fb6ac8a72eb71ca67"
  @summary_sheet ~c"xl/worksheets/sheet1.xml"
  @b2b_sheet ~c"xl/worksheets/sheet2.xml"

  @summary_cell ~s(<c r="A4" s="122" t="s"><v>74</v></c>)
  @b2b_dimension ~s(<dimension ref="A1:N5"/>)
  @sheet_data_end "</sheetData>"

  @styles %{
    invoice_number: 95,
    customer_name: 95,
    gstin: 95,
    invoice_date: 96,
    invoice_value: 97,
    tax_rate: 98,
    taxable_value: 97,
    igst: 97,
    cgst: 97,
    sgst: 97,
    cess: 97,
    state_of_supply: 95,
    reverse_charge: 95
  }

  def build(rows, title) do
    template = File.read!(Application.app_dir(:nila, @template_path))
    verify_template!(template)
    {:ok, entries} = :zip.extract(template, [:memory])

    {entries, changed} =
      Enum.map_reduce(entries, MapSet.new(), fn
        {@summary_sheet, xml}, changed ->
          replacement = text_cell("A4", 122, title)

          {{@summary_sheet, replace_once!(xml, @summary_cell, replacement)},
           MapSet.put(changed, :summary)}

        {@b2b_sheet, xml}, changed ->
          {{@b2b_sheet, patch_b2b(xml, rows)}, MapSet.put(changed, :b2b)}

        entry, changed ->
          {entry, changed}
      end)

    if changed != MapSet.new([:summary, :b2b]),
      do: raise("Winman template worksheets are missing")

    {:ok, {_name, workbook}} = :zip.create(~c"nila-winman-gstr1.xlsm", entries, [:memory])
    workbook
  end

  defp verify_template!(template) do
    actual = :sha256 |> :crypto.hash(template) |> Base.encode16(case: :lower)

    if actual != @template_sha256 do
      raise "Winman template hash mismatch: expected #{@template_sha256}, got #{actual}"
    end
  end

  defp patch_b2b(xml, rows) do
    last_row = 5 + length(rows)
    data_rows = rows |> Enum.with_index(6) |> Enum.map_join(&row_xml/1)

    xml
    |> replace_once!(@b2b_dimension, ~s(<dimension ref="A1:N#{last_row}"/>))
    |> replace_once!(@sheet_data_end, data_rows <> @sheet_data_end)
  end

  defp row_xml({row, number}) do
    cells =
      [
        text_cell("A#{number}", @styles.invoice_number, row.invoice_number),
        text_cell("B#{number}", @styles.customer_name, row.customer_name),
        text_cell("C#{number}", @styles.gstin, row.gstin),
        number_cell("D#{number}", @styles.invoice_date, excel_date(row.invoice_date)),
        number_cell("E#{number}", @styles.invoice_value, row.invoice_value),
        number_cell("F#{number}", @styles.tax_rate, row.tax_rate),
        number_cell("G#{number}", @styles.taxable_value, row.taxable_value),
        number_cell("H#{number}", @styles.igst, row.igst),
        number_cell("I#{number}", @styles.cgst, row.cgst),
        number_cell("J#{number}", @styles.sgst, row.sgst),
        number_cell("K#{number}", @styles.cess, row.cess),
        text_cell("L#{number}", @styles.state_of_supply, row.state_of_supply),
        text_cell("M#{number}", @styles.reverse_charge, row.reverse_charge),
        ~s(<c r="N#{number}" s="101"/>)
      ]
      |> IO.iodata_to_binary()

    ~s(<row r="#{number}" spans="1:14" s="89" customFormat="1" x14ac:dyDescent="0.2">#{cells}</row>)
  end

  defp text_cell(ref, style, value) when value in [nil, ""],
    do: ~s(<c r="#{ref}" s="#{style}"/>)

  defp text_cell(ref, style, value) do
    text = value |> to_string() |> escape_xml()

    ~s(<c r="#{ref}" s="#{style}" t="inlineStr"><is><t xml:space="preserve">#{text}</t></is></c>)
  end

  defp number_cell(ref, style, value) when is_number(value) do
    ~s(<c r="#{ref}" s="#{style}"><v>#{number(value)}</v></c>)
  end

  defp number(value) when is_integer(value), do: Integer.to_string(value)

  defp number(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 10])

  defp excel_date(date), do: Date.diff(date, ~D[1899-12-30])

  defp escape_xml(value) do
    if Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x{FFFE}\x{FFFF}]/u, value),
      do: raise(ArgumentError, "Winman text contains an invalid XML control character")

    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp replace_once!(source, target, replacement) do
    case :binary.matches(source, target) do
      [{offset, length}] ->
        <<before::binary-size(^offset), _target::binary-size(^length), after_target::binary>> =
          source

        before <> replacement <> after_target

      matches ->
        raise "expected one Winman template marker, found #{length(matches)}"
    end
  end
end
