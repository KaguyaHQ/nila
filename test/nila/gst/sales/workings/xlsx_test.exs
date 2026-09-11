defmodule Nila.Gst.Sales.Workings.XlsxTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Invoice.Validation, as: InvoiceValidation
  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings.Xlsx, as: WorkingsXlsx

  test "builds the three-sheet workbook and keeps tax and HSN grains separate" do
    invoice = mixed_rate_invoice()

    projection = %{
      invoices: [invoice],
      active_invoices: [invoice],
      issues: [],
      derived: Gstr1.derive([invoice], Gstr1.production_header(client().gstin, "2026-07"))
    }

    assert {:ok, workbook} =
             WorkingsXlsx.build(projection, client(), "2026-07", status: "Draft")

    assert <<"PK", _rest::binary>> = workbook

    files = entries(workbook)
    workbook_xml = Map.fetch!(files, "xl/workbook.xml")

    for name <- ["Sales", "Tax Working", "HSN"] do
      assert workbook_xml =~ ~s(name="#{name}")
    end

    strings = Map.fetch!(files, "xl/sharedStrings.xml")
    assert strings =~ "Source CGST"
    assert strings =~ "Calculated CGST"
    assert strings =~ "Silver rod"
    refute strings =~ "Filing taxable"
    refute strings =~ "source less filing"
    refute strings =~ "HSN less tax detail"
    refute strings =~ "Sales less tax detail"
    assert strings =~ "Rate-wise sales"

    tax_sheet = Map.fetch!(files, "xl/worksheets/sheet2.xml")
    assert tax_sheet =~ ~s(r="A5")
    assert tax_sheet =~ ~s(r="A6")
    assert tax_sheet =~ "SUMIFS"
    refute workbook_xml =~ "Review Trail"
    assert shared_cell(files, "xl/worksheets/sheet1.xml", "F5") == "3.0%, 18.0%"
    assert shared_cell(files, "xl/worksheets/sheet1.xml", "E5") == "33"
    assert tax_sheet =~ "ROUND(J5*I5/2,2)"
    assert tax_sheet =~ "ROUND(J6*I6/2,2)"

    hsn_sheet = Map.fetch!(files, "xl/worksheets/sheet3.xml")
    assert hsn_sheet =~ ~s(r="A5")
    assert hsn_sheet =~ ~s(r="A6")
    assert hsn_sheet =~ ~s(r="A7")
    assert hsn_sheet =~ ~s(r="A8")
    refute hsn_sheet =~ ~s(r="A9")
    assert hsn_sheet =~ "$D$5:$D$8"
    assert hsn_sheet =~ "SUMIFS"
  end

  test "refuses to manufacture an empty working" do
    projection = %{invoices: [], active_invoices: [], issues: [], derived: %{}}

    assert {:error, :no_active_sales} =
             WorkingsXlsx.build(projection, client(), "2026-07")
  end

  test "keeps missing taxable and active tax evidence blank while unused heads stay zero" do
    invoice = mixed_rate_invoice()
    [first | rest] = invoice["line_items"]

    invoice =
      Map.put(invoice, "line_items", [
        first |> Map.put("taxable_value", nil) |> Map.put("cgst_amount", nil) | rest
      ])

    projection = %{
      invoices: [invoice],
      active_invoices: [invoice],
      issues: [],
      derived: Gstr1.derive([invoice], Gstr1.production_header(client().gstin, "2026-07"))
    }

    {:ok, workbook} = WorkingsXlsx.build(projection, client(), "2026-07")
    files = entries(workbook)
    sales = files["xl/worksheets/sheet1.xml"]
    hsn = files["xl/worksheets/sheet3.xml"]

    refute sales =~ ~r/<c r="G5"[^>]*><v>/
    refute sales =~ ~r/<c r="H5"[^>]*><v>/
    assert sales =~ ~r/<c r="I5"[^>]*><v>1764(?:\.0+)?<\/v>/
    refute hsn =~ ~r/<c r="H5"[^>]*><v>/
    assert sales =~ "SUBTOTAL(102,G5:G5)"
    assert sales =~ "SUBTOTAL(103,$O$5:$O$5)"
    assert sales =~ ~r/<c r="J5"[^>]*><v>0(?:\.0+)?<\/v>/
    assert sales =~ ~r/<c r="K5"[^>]*><v>26128(?:\.0+)?<\/v>/

    files = workbook_files(Map.put(invoice, "printed_grand_total", nil))
    refute files["xl/worksheets/sheet1.xml"] =~ ~r/<c r="K5"[^>]*><v>/
    assert shared_cell(files, "xl/worksheets/sheet1.xml", "O5") == "Needs review"
    assert files["xl/workbook.xml"] =~ ~s(name="Review Trail")
    assert files["xl/worksheets/sheet2.xml"] =~ "COUNTIFS"
    assert hsn =~ "COUNT(H5,F5)"
    assert hsn =~ "COUNT(I5:K5)"
    assert hsn =~ "NOT(ISNUMBER(F"
  end

  test "missing IGST stays blank in Sales and Tax Working until an amount is supplied" do
    invoice =
      mixed_rate_invoice()
      |> Map.put("printed_grand_total", nil)
      |> Map.put("line_items", [
        %{
          "description" => "Service",
          "hsn_sac" => "998719",
          "taxable_value" => 100,
          "igst_rate" => 18,
          "igst_amount" => nil
        }
      ])

    files = workbook_files(invoice)
    sales = files["xl/worksheets/sheet1.xml"]
    refute sales =~ ~r/<c r="J5"[^>]*><v>/
    refute sales =~ ~r/<c r="K5"[^>]*><v>/
    assert sales =~ ~r/<c r="H5"[^>]*><v>0(?:\.0+)?<\/v>/
    assert sales =~ ~r/<c r="I5"[^>]*><v>0(?:\.0+)?<\/v>/
    refute files["xl/worksheets/sheet2.xml"] =~ ~r/<c r="Q5"[^>]*><v>/
    assert shared_cell(files, "xl/worksheets/sheet1.xml", "O5") == "Needs review"

    zero = put_in(invoice, ["line_items", Access.at(0), "igst_amount"], 0)
    files = workbook_files(zero)
    assert files["xl/worksheets/sheet1.xml"] =~ ~r/<c r="J5"[^>]*><v>0(?:\.0+)?<\/v>/
    assert files["xl/worksheets/sheet1.xml"] =~ ~r/<c r="K5"[^>]*><v>100(?:\.0+)?<\/v>/
  end

  test "uncharged and explicit zero-rate tax stays zero without source amounts" do
    base =
      mixed_rate_invoice()
      |> Map.put("printed_grand_total", nil)
      |> Map.put("printed_total_tax", 0)
      |> Map.put("line_items", [
        %{"description" => "Service", "hsn_sac" => "998719", "taxable_value" => 100}
      ])

    cases = [
      Map.put(base, "supply_type", "exempt"),
      Map.put(base, "reverse_charge", true),
      Map.merge(base, %{
        "supply_type" => "export",
        "tax_payment" => "without_payment",
        "buyer_gstin" => nil,
        "recipient_registration" => "unregistered"
      }),
      put_in(base, ["line_items", Access.at(0), "igst_rate"], 0)
    ]

    for invoice <- cases do
      files = workbook_files(invoice)

      for cell <- ~w(H5 I5 J5) do
        assert files["xl/worksheets/sheet1.xml"] =~ ~r/<c r="#{cell}"[^>]*><v>0(?:\.0+)?<\/v>/
      end

      assert files["xl/worksheets/sheet1.xml"] =~ ~r/<c r="K5"[^>]*><v>100(?:\.0+)?<\/v>/

      for cell <- ~w(K5 N5 Q5) do
        assert files["xl/worksheets/sheet2.xml"] =~ ~r/<c r="#{cell}"[^>]*><v>0(?:\.0+)?<\/v>/
      end
    end
  end

  test "HSN working preserves CGST and SGST treatment when explicit place of supply is absent" do
    invoice = mixed_rate_invoice() |> Map.put("place_of_supply", nil)

    projection = %{
      invoices: [invoice],
      active_invoices: [invoice],
      issues: [],
      derived: Gstr1.derive([invoice], Gstr1.production_header(client().gstin, "2026-07"))
    }

    {:ok, workbook} = WorkingsXlsx.build(projection, client(), "2026-07")
    files = entries(workbook)

    for row <- 5..8 do
      assert shared_cell(files, "xl/worksheets/sheet3.xml", "G#{row}") == "Intrastate"
    end

    assert shared_cell(files, "xl/worksheets/sheet2.xml", "H5") == "Intrastate"
  end

  test "review trail appears for unresolved issues and corrections" do
    invoice = Map.put(mixed_rate_invoice(), "id", "source-1")

    issue = %{
      "status" => "open",
      "source_id" => "source-1",
      "code" => "amount_mismatch",
      "message" => "Check invoice total"
    }

    projection = %{
      invoices: [invoice],
      active_invoices: [invoice],
      issues: [issue],
      derived: Gstr1.derive([invoice], Gstr1.production_header(client().gstin, "2026-07"))
    }

    {:ok, workbook} = WorkingsXlsx.build(projection, client(), "2026-07")
    files = entries(workbook)
    assert files["xl/workbook.xml"] =~ ~s(name="Review Trail")
    assert files["xl/sharedStrings.xml"] =~ "Check invoice total"
    assert shared_cell(files, "xl/worksheets/sheet4.xml", "B5") == "46/2026-27"
  end

  test "HSN quantity summaries keep different units separate" do
    invoice = mixed_rate_invoice()
    base = Enum.at(invoice["line_items"], 1)

    invoice =
      Map.put(invoice, "line_items", [
        Map.merge(base, %{"uom" => "Nos", "quantity" => 2}),
        Map.merge(base, %{"uom" => "Kg", "quantity" => 3})
      ])

    projection = %{
      invoices: [invoice],
      active_invoices: [invoice],
      issues: [],
      derived: Gstr1.derive([invoice], Gstr1.production_header(client().gstin, "2026-07"))
    }

    {:ok, workbook} = WorkingsXlsx.build(projection, client(), "2026-07")
    files = entries(workbook)
    assert shared_cell(files, "xl/worksheets/sheet3.xml", "D10") == "KGS"
    assert shared_cell(files, "xl/worksheets/sheet3.xml", "D11") == "NOS"
    assert files["xl/worksheets/sheet3.xml"] =~ "SUMIFS($E$5:$E$6"
    assert files["xl/worksheets/sheet3.xml"] =~ "$D$5:$D$6,D10"
  end

  test "source tax in an unexpected head is preserved for the arithmetic check" do
    invoice = mixed_rate_invoice()
    [first | rest] = invoice["line_items"]
    invoice = Map.put(invoice, "line_items", [Map.put(first, "igst_amount", 7) | rest])

    projection = %{
      invoices: [invoice],
      active_invoices: [invoice],
      issues: [],
      derived: Gstr1.derive([invoice], Gstr1.production_header(client().gstin, "2026-07"))
    }

    {:ok, workbook} = WorkingsXlsx.build(projection, client(), "2026-07")
    files = entries(workbook)
    # Printed CGST/SGST survive even when the unexpected IGST makes this bucket interstate.
    sheet = files["xl/worksheets/sheet2.xml"]
    assert sheet =~ ~r/<c r="K5"[^>]*><v>54(?:\.0)?<\/v>/
    assert sheet =~ ~r/<c r="Q5"[^>]*><v>7(?:\.0)?<\/v>/

    sales = files["xl/worksheets/sheet1.xml"]
    assert sales =~ ~r/<c r="H5"[^>]*><v>1764(?:\.0)?<\/v>/
    assert sales =~ ~r/<c r="I5"[^>]*><v>1764(?:\.0)?<\/v>/
    assert sales =~ ~r/<c r="J5"[^>]*><v>7(?:\.0)?<\/v>/
  end

  test "accepted line rounding stays informational and identifies its invoice" do
    invoice = mixed_rate_invoice() |> Map.put("id", "rounding-source")

    lines =
      for _ <- 1..6,
          do:
            line("Small item", "74121000", 100.06, 18, 1)
            |> Map.merge(%{"cgst_amount" => 9.01, "sgst_amount" => 9.01})

    invoice = Map.put(invoice, "line_items", lines)

    issues =
      InvoiceValidation.issues([invoice])
      |> Enum.filter(&(&1["code"] == "rounding_variance"))
      |> Enum.map(&Map.put(&1, "status", "open"))

    assert length(issues) == 2

    projection = %{
      invoices: [invoice],
      active_invoices: [invoice],
      issues: issues,
      derived: Gstr1.derive([invoice], Gstr1.production_header(client().gstin, "2026-07"))
    }

    {:ok, workbook} = WorkingsXlsx.build(projection, client(), "2026-07")
    files = entries(workbook)
    assert shared_cell(files, "xl/worksheets/sheet4.xml", "A5") == "Information"
    assert shared_cell(files, "xl/worksheets/sheet4.xml", "B5") == "46/2026-27"
    assert files["xl/sharedStrings.xml"] =~ "CGST line-tax sum"
    refute files["xl/sharedStrings.xml"] =~ "GSTR-1 reconciliation"
    assert files["xl/worksheets/sheet2.xml"] =~ "Rounding"
    assert files["xl/worksheets/sheet2.xml"] =~ "ABS(M5-(0.03))"
  end

  test "sales subtotal follows filters and short rows stay compact" do
    invoice = mixed_rate_invoice()

    projection = %{
      invoices: [invoice],
      active_invoices: [invoice],
      issues: [],
      derived: Gstr1.derive([invoice], Gstr1.production_header(client().gstin, "2026-07"))
    }

    {:ok, workbook} = WorkingsXlsx.build(projection, client(), "2026-07")
    files = entries(workbook)
    sheet = files["xl/worksheets/sheet1.xml"]
    assert sheet =~ "SUBTOTAL(109,G5:G5)"
    assert sheet =~ "SUBTOTAL(109,K5:K5)"
    refute sheet =~ "32.25"
    assert shared_cell(files, "xl/worksheets/sheet1.xml", "A4") == "Invoice no."
    assert shared_cell(files, "xl/worksheets/sheet1.xml", "P4") == "Source"
  end

  defp workbook_files(invoice) do
    invoice = Map.put(invoice, "id", "missing-amount-source")
    issues = InvoiceValidation.issues([invoice]) |> Enum.map(&Map.put(&1, "status", "open"))

    projection = %{
      invoices: [invoice],
      active_invoices: [invoice],
      issues: issues,
      derived: Gstr1.derive([invoice], Gstr1.production_header(client().gstin, "2026-07"))
    }

    {:ok, workbook} = WorkingsXlsx.build(projection, client(), "2026-07")
    entries(workbook)
  end

  defp shared_cell(files, sheet, address) do
    [_, index] =
      Regex.run(~r/<c r="#{address}"[^>]*t="s"[^>]*><v>(\d+)<\/v><\/c>/, Map.fetch!(files, sheet))

    strings =
      Regex.scan(
        ~r/<si><t(?: [^>]*)?>(.*?)<\/t><\/si>/s,
        Map.fetch!(files, "xl/sharedStrings.xml")
      )

    strings |> Enum.at(String.to_integer(index)) |> Enum.at(1)
  end

  defp mixed_rate_invoice do
    Normalizer.normalize(%{
      "data" => %{
        "document_type" => "invoice",
        "document_status" => "active",
        "supply_type" => "taxable",
        "recipient_registration" => "registered",
        "place_of_supply" => "33",
        "invoice_number" => "46/2026-27",
        "invoice_date" => "15.07.2026",
        "seller" => %{"name" => "Caltech Refrigeration", "gstin" => client().gstin},
        "buyer" => %{"name" => "Buyer One", "gstin" => "33AAVCS8021P1ZB"},
        "line_items" => [
          line("Silver rod", "71069290", 3_600, 3, 6),
          line("Copper fitting", "74121000", 1_500, 18, 3),
          line("Repair service", "998719", 17_000, 18, 5),
          line("Rubber hose", "40093200", 500, 18, 1)
        ],
        "printed_total_taxable" => 22_600,
        "printed_total_tax" => 3_528,
        "printed_grand_total" => 26_128
      }
    })
  end

  defp line(description, hsn, taxable, rate, quantity) do
    tax = taxable * rate / 200

    %{
      "description" => description,
      "hsn_description" => description,
      "hsn_sac" => hsn,
      "uom" => "Nos",
      "quantity" => quantity,
      "taxable_value" => taxable,
      "cgst_rate" => rate / 2,
      "cgst_amount" => tax,
      "sgst_rate" => rate / 2,
      "sgst_amount" => tax,
      "igst_rate" => 0,
      "igst_amount" => 0
    }
  end

  defp client do
    %{name: "Caltech Refrigeration", gstin: "33BPBPK1081A1ZO"}
  end

  defp entries(workbook) do
    {:ok, entries} = :zip.extract(workbook, [:memory])
    Map.new(entries, fn {path, bytes} -> {List.to_string(path), bytes} end)
  end
end
