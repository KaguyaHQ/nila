defmodule Nila.Gst.Filing.WinmanGstr1Test do
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.WinmanGstr1

  @template_path "priv/templates/winman/gstr1-9.5.6-fy2026-27.xlsm"

  test "writes B2B tax-rate rows while preserving the Winman package" do
    projection = %{
      invoices: [
        %{
          "invoice_number" => "INV&001",
          "buyer_name" => "Buyer & Co",
          "buyer_gstin" => "33AABCP9487A1ZG"
        }
      ],
      derived: %{
        "b2b" => [
          %{
            "ctin" => "33AABCP9487A1ZG",
            "inv" => [
              %{
                "inum" => "INV&001",
                "idt" => "15-07-2026",
                "val" => 1770.0,
                "pos" => "35",
                "rchrg" => "N",
                "itms" => [
                  %{
                    "itm_det" => %{
                      "rt" => 5,
                      "txval" => 1000.0,
                      "iamt" => 50.0,
                      "camt" => 0,
                      "samt" => 0,
                      "csamt" => 0
                    }
                  },
                  %{
                    "itm_det" => %{
                      "rt" => 18,
                      "txval" => 610.17,
                      "iamt" => 109.83,
                      "camt" => 0,
                      "samt" => 0,
                      "csamt" => 0
                    }
                  }
                ]
              }
            ]
          }
        ]
      }
    }

    assert {:ok, workbook} = WinmanGstr1.build(projection, %{name: "Nila & Co"}, "2026-07")

    original = template_entries()
    generated = entries(workbook)
    changed = ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"]

    assert Map.drop(generated, changed) == Map.drop(original, changed)
    assert Map.keys(generated) |> Enum.sort() == Map.keys(original) |> Enum.sort()
    assert generated["xl/vbaProject.bin"] == original["xl/vbaProject.bin"]
    assert generated["xl/vbaProjectSignature.bin"] == original["xl/vbaProjectSignature.bin"]

    summary = generated["xl/worksheets/sheet1.xml"]
    assert summary =~ "Nila &amp; Co_26-27.wgst - GST - F.Y. : 2026-2027"

    b2b = generated["xl/worksheets/sheet2.xml"]
    assert b2b =~ ~s(<dimension ref="A1:N7"/>)
    assert b2b =~ ~s(<row r="6" spans="1:14")
    assert b2b =~ ~s(<row r="7" spans="1:14")
    assert b2b =~ "INV&amp;001"
    assert b2b =~ "Buyer &amp; Co"
    assert b2b =~ "Andaman &amp; Nicobar Islands"
    assert b2b =~ ">No<"

    serial = Date.diff(~D[2026-07-15], ~D[1899-12-30])
    assert b2b =~ ~s(<c r="D6" s="96"><v>#{serial}</v></c>)
    assert b2b =~ ~s(<c r="F6" s="98"><v>5</v></c>)
    assert b2b =~ ~s(<c r="F7" s="98"><v>18</v></c>)
  end

  test "keeps the hidden Winman row and an empty B2B sheet when there are no rows" do
    projection = %{invoices: [], derived: %{"b2b" => []}}

    assert {:ok, workbook} = WinmanGstr1.build(projection, %{name: "Empty Client"}, "2027-03")
    b2b = entries(workbook)["xl/worksheets/sheet2.xml"]

    assert b2b =~ ~s(<dimension ref="A1:N5"/>)
    assert b2b =~ ~s(<row r="5" spans="1:14" s="89" customFormat="1" hidden="1")
    refute b2b =~ ~s(<row r="6" spans="1:14")
  end

  test "rejects periods outside the bundled Winman financial year" do
    projection = %{invoices: [], derived: %{"b2b" => []}}

    assert {:error, :unsupported_period} =
             WinmanGstr1.build(projection, %{name: "Client"}, "2025-10")

    refute WinmanGstr1.supported_period?("2025-10")
    assert WinmanGstr1.supported_period?("2026-04")
    assert WinmanGstr1.supported_period?("2027-03")
  end

  test "rejects malformed B2B rows instead of emitting broken Excel cells" do
    projection = %{
      invoices: [],
      derived: %{
        "b2b" => [
          %{
            "ctin" => "29AAVCS8021P1ZB",
            "inv" => [
              %{
                "inum" => "INV-1",
                "idt" => "not-a-date",
                "val" => 1180,
                "pos" => "29",
                "itms" => [%{"itm_det" => %{"rt" => 18, "txval" => 1000}}]
              }
            ]
          }
        ]
      }
    }

    assert {:error, :invalid_b2b_data} =
             WinmanGstr1.build(projection, %{name: "Client"}, "2026-07")
  end

  test "normalizes recipient GSTINs before writing them" do
    projection = %{
      invoices: [],
      derived: %{
        "b2b" => [
          %{
            "ctin" => " 33aabcp9487a1zg ",
            "inv" => [
              %{
                "inum" => "INV-1",
                "idt" => "15-07-2026",
                "val" => 1180,
                "pos" => "33",
                "rchrg" => "N",
                "itms" => [
                  %{
                    "itm_det" => %{
                      "rt" => 18,
                      "txval" => 1000,
                      "iamt" => 0,
                      "camt" => 90,
                      "samt" => 90,
                      "csamt" => 0
                    }
                  }
                ]
              }
            ]
          }
        ]
      }
    }

    assert {:ok, workbook} = WinmanGstr1.build(projection, %{name: "Client"}, "2026-07")
    assert entries(workbook)["xl/worksheets/sheet2.xml"] =~ ">33AABCP9487A1ZG<"
  end

  test "rejects XML 1.0 noncharacters before packaging" do
    projection = %{invoices: [], derived: %{"b2b" => []}}

    assert {:error, :invalid_b2b_data} =
             WinmanGstr1.build(projection, %{name: "Bad\uFFFFClient"}, "2026-07")
  end

  test "the bundled template contains no source-client or external-link residue" do
    template = template_entries()

    refute Enum.any?(Map.keys(template), &String.starts_with?(&1, "xl/externalLinks/"))

    assert template
           |> Map.values()
           |> Enum.all?(fn bytes ->
             :binary.match(bytes, "DEVARAJAN KANNAN") == :nomatch and
               :binary.match(bytes, "\\\\Pc2\\") == :nomatch
           end)

    workbook = template["xl/workbook.xml"]
    refute workbook =~ "externalReference"
    refute workbook =~ "absPath"
  end

  defp template_entries do
    @template_path
    |> then(&Application.app_dir(:nila, &1))
    |> File.read!()
    |> entries()
  end

  defp entries(workbook) do
    {:ok, entries} = :zip.extract(workbook, [:memory])
    Map.new(entries, fn {path, bytes} -> {List.to_string(path), bytes} end)
  end
end
