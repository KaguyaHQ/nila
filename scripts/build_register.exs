alias Elixlsx.{Workbook, Sheet}

defmodule RegisterBuildScript do
  @moduledoc false

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [books: :string, gstr2b: :string, corrections: :string, out: :string,
                 entity_name: :string, gstin: :string, address: :string, period: :string]
      )

    books_path = req!(opts, :books)
    g2b_path = req!(opts, :gstr2b)
    out_dir = Path.expand(opts[:out] || "tmp/register")
    period = opts[:period] || "period"

    books_doc = books_path |> File.read!() |> Jason.decode!()

    invoices =
      books_doc["invoices"]
      |> Enum.map(&decode_date/1)
      |> apply_corrections(opts[:corrections])

    {:ok, g2b} = Nila.Gst.Gstr2b.parse(File.read!(g2b_path))

    entity_ctx = %{
      "gstin" => req!(opts, :gstin),
      "entity_name" => opts[:entity_name],
      "state_code" => String.slice(req!(opts, :gstin), 0, 2),
      "registered_address" => opts[:address],
      "business_hsn_prefixes" => [],
      "residential_markers" => []
    }

    vendor_dir = Map.new(g2b, fn g -> {g["vendor_gstin"], g["vendor_name"]} end)
    recon = Nila.Gst.Recon.reconcile(invoices, g2b)
    flags = Nila.Gst.Flags.evaluate_all(invoices, entity_ctx, vendor_dir)
    rows = Nila.Gst.Register.rows(invoices, recon, flags)
    summary = Nila.Gst.Register.summary(rows)

    File.mkdir_p!(out_dir)
    copy_images(books_path, out_dir, rows)

    xlsx_path = Path.join(out_dir, "purchase_register_#{period}.xlsx")
    write_xlsx(rows, summary, xlsx_path)

    File.write!(Path.join(out_dir, "register_rows.json"), Jason.encode!(rows, pretty: true))
    File.write!(Path.join(out_dir, "recon.json"), Jason.encode!(recon, pretty: true))
    File.write!(Path.join(out_dir, "summary.json"), Jason.encode!(summary, pretty: true))

    zip_path = Path.join(out_dir, "register_#{period}.zip")
    zip_deliverable(zip_path, xlsx_path, out_dir)

    IO.puts("rows: #{length(rows)}  buckets: #{inspect(summary["buckets"])}")
    IO.puts("wrote #{xlsx_path}")
    IO.puts("wrote #{zip_path}")
  end

  defp req!(opts, key), do: opts[key] || Mix.raise("--#{key} is required")

  defp decode_date(inv) do
    Map.update!(inv, "invoice_date", fn
      nil -> nil
      %Date{} = d -> d
      s -> Date.from_iso8601!(s)
    end)
  end

  defp apply_corrections(invoices, nil), do: invoices

  defp apply_corrections(invoices, path) do
    corrections = path |> File.read!() |> Jason.decode!() |> Map.fetch!("corrections")

    Enum.map(invoices, fn inv ->
      Enum.reduce(corrections, inv, fn c, acc ->
        if acc["invoice_number"] == c["invoice"],
          do: Map.put(acc, c["field"], c["value"]),
          else: acc
      end)
    end)
  end

  defp copy_images(books_path, out_dir, rows) do
    src_images = Path.join(Path.dirname(books_path), "images")
    dst_images = Path.join(out_dir, "images")
    File.mkdir_p!(dst_images)

    rows
    |> Enum.flat_map(& &1["images"])
    |> Enum.uniq()
    |> Enum.each(fn rel ->
      src = Path.join(Path.dirname(books_path), rel)
      src = if File.exists?(src), do: src, else: Path.join(src_images, Path.basename(rel))
      if File.exists?(src), do: File.cp!(src, Path.join(dst_images, Path.basename(rel)))
    end)
  end

  defp write_xlsx(rows, summary, xlsx_path) do
    money = fn paise -> paise / 100 end

    header = [
      "S.No", "Inv No", "Date", "Vendor", "GSTIN", "Taxable", "CGST", "SGST", "IGST",
      "Total", "2B Status", "Flags", "Note / Next Action", "Evidence"
    ]

    data_rows =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {row, idx} ->
        [
          idx,
          row["invoice_number"],
          date_str(row["invoice_date"]),
          row["vendor_name"],
          row["vendor_gstin"],
          money.(row["taxable_paise"]),
          money.(row["cgst_paise"]),
          money.(row["sgst_paise"]),
          money.(row["igst_paise"]),
          money.(row["total_paise"]),
          row["bucket_label"],
          row["flag_summary"] || "",
          row["recon_note"] || row["next_action"] || "",
          evidence_label(row)
        ]
      end)

    register_sheet = %Sheet{Sheet.with_name("Purchase Register") | rows: [header | data_rows]}

    summary_rows =
      [["Purchase register summary", ""]] ++
        [["Invoices in books", summary["total_invoices"]]] ++
        Enum.map(summary["buckets"], fn {bucket, count} -> [bucket, count] end) ++
        [["", ""], ["Flags", ""]] ++
        Enum.map(summary["flag_counts"], fn {code, count} -> [code, count] end)

    summary_sheet = %Sheet{Sheet.with_name("Summary") | rows: summary_rows}

    {:ok, _} =
      %Workbook{}
      |> Workbook.append_sheet(register_sheet)
      |> Workbook.append_sheet(summary_sheet)
      |> Elixlsx.write_to(xlsx_path)

    inject_hyperlinks(xlsx_path, rows)
  end

  defp date_str(nil), do: ""
  defp date_str(%Date{} = d), do: Calendar.strftime(d, "%d-%m-%Y")

  defp evidence_label(%{"pages" => []}), do: ""
  defp evidence_label(%{"pages" => pages}), do: "page " <> Enum.map_join(pages, ",", &to_string/1)

  defp inject_hyperlinks(xlsx_path, rows) do
    linked =
      rows
      |> Enum.with_index(1)
      |> Enum.reject(fn {row, _} -> row["images"] == [] end)

    {:ok, entries} = :zip.unzip(String.to_charlist(xlsx_path), [:memory])
    entries = Map.new(entries, fn {name, bin} -> {to_string(name), bin} end)

    rels =
      Enum.map_join(linked, fn {row, idx} ->
        target = "images/" <> Path.basename(hd(row["images"]))

        ~s|<Relationship Id="rIdHl#{idx}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="#{target}" TargetMode="External"/>|
      end)

    sheet_rels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">#{rels}</Relationships>
    """

    hyperlinks_xml =
      Enum.map_join(linked, fn {_row, idx} ->
        ~s|<hyperlink ref="N#{idx + 1}" r:id="rIdHl#{idx}"/>|
      end)

    sheet1 = Map.fetch!(entries, "xl/worksheets/sheet1.xml")

    unless String.contains?(sheet1, "<pageMargins"),
      do: Mix.raise("expected <pageMargins in sheet1.xml")

    sheet1 =
      String.replace(sheet1, "<pageMargins", "<hyperlinks>#{hyperlinks_xml}</hyperlinks><pageMargins",
        global: false
      )

    entries =
      entries
      |> Map.put("xl/worksheets/sheet1.xml", sheet1)
      |> Map.put("xl/worksheets/_rels/sheet1.xml.rels", sheet_rels)

    zip_entries = Enum.map(entries, fn {name, bin} -> {String.to_charlist(name), bin} end)
    {:ok, _} = :zip.create(String.to_charlist(xlsx_path), zip_entries)
    :ok
  end

  defp zip_deliverable(zip_path, xlsx_path, out_dir) do
    images =
      out_dir
      |> Path.join("images/*.png")
      |> Path.wildcard()
      |> Enum.map(fn p ->
        {String.to_charlist("images/" <> Path.basename(p)), File.read!(p)}
      end)

    entries = [{String.to_charlist(Path.basename(xlsx_path)), File.read!(xlsx_path)} | images]
    {:ok, _} = :zip.create(String.to_charlist(zip_path), entries)
  end
end

RegisterBuildScript.run(System.argv())
