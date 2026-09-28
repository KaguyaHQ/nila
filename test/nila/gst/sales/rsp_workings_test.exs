defmodule Nila.Gst.Sales.RspWorkingsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.{Gstr1, Workings}
  alias Nila.Gst.Sales.Excel.ReturnReport

  test "a section report's net HSN evidence survives validation and return projection" do
    {invoices, report} = fixture()
    working = materialize(invoices, report)

    assert Enum.all?(working.active_invoices, &(&1["tax_valuation"]["status"] == "derived"))
    assert [%{"inv" => [sale]}] = working.derived["b2b"]
    assert sale["val"] == 128.57
    assert [%{"itm_det" => sale_tax}] = sale["itms"]

    assert Map.take(sale_tax, ~w(txval camt samt iamt rt)) ==
             %{"txval" => 100.0, "camt" => 14.28, "samt" => 14.29, "iamt" => 0.0, "rt" => 40}

    assert [%{"nt" => [credit]}] = working.derived["cdnr"]
    assert credit["val"] == 25.71
    assert [%{"itm_det" => credit_tax}] = credit["itms"]
    assert credit_tax["camt"] == 2.85
    assert credit_tax["samt"] == 2.86
    assert credit_tax["txval"] == 20.0

    refute Enum.any?(
             working.issues,
             &(&1["code"] in ~w(line_arithmetic bucket_tax_mismatch grand_total_mismatch rsp_tax_unresolved))
           )

    replay = materialize(working.invoices, report)
    assert replay.derived == working.derived
    assert replay.active_invoices == working.active_invoices

    assert Enum.map(replay.invoices, & &1["return_report_values"]) ==
             Enum.map(invoices, & &1["return_report_values"])
  end

  test "a taxable correction invalidates the population proof on replay" do
    {invoices, report} = fixture()
    working = materialize(invoices, report)
    sale = Enum.find(working.invoices, &(&1["return_report_section"] == "B2B"))

    resolution = %{
      "verb" => "correct_field",
      "target" => sale["id"],
      "payload" => %{"field" => "line_items[0].taxable_value", "to" => 101.0}
    }

    corrected = materialize(working.invoices, report, [resolution])
    assert corrected.silent_errors == []
    corrected_sale = Enum.find(corrected.invoices, &(&1["id"] == sale["id"]))
    assert hd(corrected_sale["line_items"])["taxable_value"] == 101.0
    assert hd(corrected_sale["return_report_values"])["txval"] == 100.0
    assert_unresolved(corrected)
  end

  test "an HSN discrepancy leaves tax missing and blocks export instead of calculating by rate" do
    {invoices, report} = fixture()

    report =
      update_in(report, ["rows"], fn rows ->
        Enum.map(rows, fn row ->
          if row["section"] == "hsn_b2b",
            do: put_in(row, ["values", "txval"], 90.0),
            else: row
        end)
      end)

    assert_unresolved(materialize(invoices, report))
  end

  defp assert_unresolved(working) do
    assert working.derived["b2b"] == []
    assert working.derived["cdnr"] == []

    for invoice <- working.active_invoices do
      assert invoice["tax_valuation"]["status"] == "unresolved"
      assert hd(invoice["line_items"])["cgst_amount"] == nil
      assert hd(invoice["line_items"])["sgst_amount"] == nil
      assert Gstr1.filing_details(invoice) == []

      assert Enum.any?(working.issues, fn issue ->
               issue["source_id"] == invoice["id"] and issue["code"] == "rsp_tax_unresolved" and
                 issue["level"] == "blocking" and issue["status"] == "open"
             end)
    end
  end

  defp materialize(invoices, report, resolutions \\ []) do
    Workings.materialize(
      invoices,
      resolutions,
      Gstr1.production_header("33ABCFR6054J1Z5", "2026-08"),
      [], return_reports: [report])
  end

  defp fixture do
    rows = [source_row("B2B", "A1", 100.0, 128.57), source_row("CDNR", "C1", 20.0, 25.71)]

    hsn = %{
      "section" => "hsn_b2b",
      "sheet" => "HSN(B2B)",
      "row" => 2,
      "source_filename" => "HSN(B2B).xlsx",
      "values" => %{
        "hsn_sc" => "24022030",
        "uqc" => "NOS",
        "qty" => 8.0,
        "rate" => 40.0,
        "txval" => 80.0,
        "camt" => 11.43,
        "samt" => 11.43,
        "iamt" => 0.0,
        "csamt" => 0.0
      }
    }

    report = %{
      "format" => "standard_gstr1_sections",
      "dump_id" => 12,
      "filename" => "report.xlsx",
      "rows" => rows ++ [hsn]
    }

    invoices =
      ReturnReport.invoices(report, %{gstin: "33ABCFR6054J1Z5"})
      |> Enum.map(&Map.put(&1, "return_report_dump_id", 12))

    {invoices, report}
  end

  defp source_row(section, number, taxable, total) do
    %{
      "section" => String.downcase(section),
      "sheet" => section,
      "row" => 2,
      "source_filename" => section <> ".xlsx",
      "values" => %{
        "seller_gstin" => "33ABCFR6054J1Z5",
        "buyer_gstin" => "33AAVCS8021P1ZB",
        "buyer_name" => "Buyer",
        "number" => number,
        "date" => "2026-08-01",
        "value" => total,
        "txval" => taxable,
        "rate" => 40.0,
        "camt" => taxable * 0.2,
        "samt" => taxable * 0.2,
        "iamt" => 0.0,
        "csamt" => 0.0,
        "pos" => "33-Tamil Nadu",
        "reverse_charge" => "N",
        "invoice_type" => "R",
        "note_type" => "C"
      }
    }
  end
end
