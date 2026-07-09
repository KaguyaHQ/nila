# Spike: purchase register .xlsx with clickable evidence links to sibling images/ folder.
# Two mechanisms per row, for A/B testing on Windows Excel:
#   col G "evidence_formula" -> =HYPERLINK("images/page_0N.png","view") formula cell (native elixlsx)
#   col H "evidence_link"    -> plain text cell + injected <hyperlinks> relationship (post-processed zip)
# Run: mix run --no-start scripts/spike_register_xlsx.exs
# Output: /tmp/register_spike/{register.xlsx, images/page_01..05.png}

alias Elixlsx.{Workbook, Sheet}

out_dir = "/tmp/register_spike"
img_dir = Path.join(out_dir, "images")
File.rm_rf!(out_dir)
File.mkdir_p!(img_dir)

png =
  Base.decode64!(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

rows_data = [
  {"INV-1001", "Acme Traders", "33AAACA1111A1Z5", 12_500.0, 2250.0, "ok", 1},
  {"INV-1002", "Bharat Steel", "29AABCB2222B1Z4", 84_000.0, 15_120.0, "gstin_mismatch", 2},
  {"INV-1003", "Chennai Papers", "33AACCC3333C1Z3", 5600.0, 1008.0, "ok", 3},
  {"INV-1004", "Delta Logistics", "07AADCD4444D1Z2", 31_250.0, 5625.0, "duplicate?", 4},
  {"INV-1005", "Everest Foods", "32AAECE5555E1Z1", 9800.0, 490.0, "rate_check", 5}
]

for {_, _, _, _, _, _, n} <- rows_data do
  File.write!(Path.join(img_dir, "page_0#{n}.png"), png)
end

header = ["invoice_no", "vendor", "gstin", "taxable", "tax", "flags", "evidence_formula", "evidence_link"]

rows =
  for {inv, vendor, gstin, taxable, tax, flags, n} <- rows_data do
    [
      inv,
      vendor,
      gstin,
      taxable,
      tax,
      flags,
      {:formula, ~s|HYPERLINK("images/page_0#{n}.png","view p#{n}")|},
      "open p#{n}"
    ]
  end

sheet = %Sheet{Sheet.with_name("Register") | rows: [header | rows]}
xlsx_path = Path.join(out_dir, "register.xlsx")
{:ok, _} = Workbook.append_sheet(%Workbook{}, sheet) |> Elixlsx.write_to(xlsx_path)

# --- post-process: inject <hyperlinks> rels for column H (rows 2..6) ---

{:ok, entries} = :zip.unzip(String.to_charlist(xlsx_path), [:memory])
entries = Map.new(entries, fn {name, bin} -> {to_string(name), bin} end)

hyperlink_rows = for {_, _, _, _, _, _, n} <- rows_data, do: n

rels =
  hyperlink_rows
  |> Enum.map(fn n ->
    ~s|<Relationship Id="rIdHl#{n}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="images/page_0#{n}.png" TargetMode="External"/>|
  end)
  |> Enum.join()

sheet_rels = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">#{rels}</Relationships>
"""

hyperlinks_xml =
  hyperlink_rows
  |> Enum.map(fn n -> ~s|<hyperlink ref="H#{n + 1}" r:id="rIdHl#{n}"/>| end)
  |> Enum.join()

sheet1 = entries["xl/worksheets/sheet1.xml"]

unless String.contains?(sheet1, "<pageMargins"), do: raise("expected <pageMargins in sheet1.xml")

sheet1 =
  String.replace(
    sheet1,
    "<pageMargins",
    "<hyperlinks>#{hyperlinks_xml}</hyperlinks><pageMargins",
    global: false
  )

entries =
  entries
  |> Map.put("xl/worksheets/sheet1.xml", sheet1)
  |> Map.put("xl/worksheets/_rels/sheet1.xml.rels", sheet_rels)

zip_entries = Enum.map(entries, fn {name, bin} -> {String.to_charlist(name), bin} end)
{:ok, _} = :zip.create(String.to_charlist(xlsx_path), zip_entries)

# --- deliverable zip: register.xlsx + images/ ---

zip_path = Path.join(out_dir, "register_spike.zip")

deliverable =
  [{~c"register.xlsx", File.read!(xlsx_path)}] ++
    Enum.map(hyperlink_rows, fn n ->
      {String.to_charlist("images/page_0#{n}.png"), png}
    end)

{:ok, _} = :zip.create(String.to_charlist(zip_path), deliverable)

IO.puts("wrote #{xlsx_path}")
IO.puts("wrote #{zip_path}")
