defmodule Nila.Gst.Sales.RspValuationTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.{Invoice, RspValuation}

  test "derives only single-rate registered rows when net taxable and tax match a notified HSN summary" do
    invoices = [invoice("B2B", "A", 100, 128.57), invoice("CDNR", "C", 20, 25.71)]
    [sale, credit] = RspValuation.apply(invoices, [report([hsn(80, 11.43, 11.43)])])

    assert sale["tax_valuation"]["status"] == "derived"
    assert sale["tax_valuation"]["method"] == "invoice_value_residual"
    assert sale["tax_valuation"]["reconciliation"]["difference"] == 0.0

    assert sale["line_items"] |> hd() |> Map.take(~w(cgst_amount sgst_amount tax_amount_basis)) ==
             %{
               "cgst_amount" => 14.28,
               "sgst_amount" => 14.29,
               "tax_amount_basis" => "invoice_value_residual"
             }

    assert credit["line_items"] |> hd() |> Map.take(~w(cgst_amount sgst_amount)) ==
             %{"cgst_amount" => 2.85, "sgst_amount" => 2.86}

    assert Nila.Gst.Sales.TaxDetermination.working_tax(sale["line_items"]).camt == 14.28
  end

  test "registered note repeated in CDNR and CDNUR retains one financial line" do
    sale = invoice("B2B", "A", 100, 128.57)
    credit = invoice("CDNR", "C", 20, 25.71)
    [source] = credit["return_report_values"]
    copied = Map.put(source, "source_ur_type", "33CMJPT7908P1Z5")
    credit = %{credit | "return_report_values" => [source, copied]}

    [_, result] = RspValuation.apply([sale, credit], [report([hsn(80, 11.43, 11.43)])])
    assert result["tax_valuation"]["status"] == "derived"
    assert length(result["line_items"]) == 1
  end

  test "one changed total invalidates the group and removes synthetic tax amounts" do
    invoices = [invoice("B2B", "A", 100, 128.57), invoice("CDNR", "C", 20, 25.71)]
    changed = List.update_at(invoices, 0, &Map.put(&1, "printed_grand_total", 130.0))
    [sale, credit] = RspValuation.apply(changed, [report([hsn(80, 11.43, 11.43)])])

    assert sale["tax_valuation"]["status"] == "unresolved"
    assert credit["tax_valuation"]["status"] == "unresolved"
    assert hd(sale["line_items"])["cgst_amount"] == nil
    assert hd(credit["line_items"])["cgst_amount"] == nil
  end

  test "a 40 percent rate without notified HSN evidence keeps ordinary tax" do
    [sale] = RspValuation.apply([invoice("B2B", "A", 100, 140)], [report([])])
    refute sale["tax_valuation"]
    assert hd(sale["line_items"])["cgst_amount"] == 20.0
  end

  test "mixed rate invoice prevents a matching net from proving the population" do
    sale = invoice("B2B", "A", 100, 128.57)

    extra = %{
      hd(sale["line_items"])
      | "taxable_value" => 5.0,
        "cgst_rate" => 2.5,
        "sgst_rate" => 2.5,
        "cgst_amount" => 0.13,
        "sgst_amount" => 0.13
    }

    mixed = %{
      sale
      | "line_items" => sale["line_items"] ++ [extra],
        "return_report_values" =>
          sale["return_report_values"] ++
            [%{"rate" => 5.0, "txval" => 5.0, "date" => "2026-08-01"}]
    }

    [result] = RspValuation.apply([mixed], [report([hsn(100, 14.28, 14.29)])])
    assert result["tax_valuation"]["status"] == "unresolved"
    assert Enum.at(result["line_items"], 1)["cgst_amount"] == 0.13
  end

  test "duplicated source rows without one line do not crash the review" do
    sale = invoice("B2B", "A", 100, 128.57)

    two_lines = %{
      sale
      | "line_items" => sale["line_items"] ++ sale["line_items"],
        "return_report_values" => sale["return_report_values"] ++ sale["return_report_values"]
    }

    [result] = RspValuation.apply([two_lines], [report([hsn(100, 14.28, 14.29)])])
    assert result["tax_valuation"]["status"] == "unresolved"
  end

  test "a pre-effective sale cannot be included in an RSP population" do
    before = invoice("B2B", "A", 100, 128.57)

    before = %{
      before
      | "invoice_date" => ~D[2026-01-31],
        "return_report_values" => [
          Map.put(hd(before["return_report_values"]), "date", "2026-01-31")
        ]
    }

    [result] = RspValuation.apply([before], [report([hsn(100, 14.28, 14.29)])])
    refute result["tax_valuation"]
  end

  test "reviewer-entered tax is preserved when the population no longer reconciles" do
    sale = invoice("B2B", "A", 100, 128.57)
    [line] = sale["line_items"]
    changed = %{sale | "line_items" => [%{line | "cgst_amount" => 15.0, "sgst_amount" => 15.0}]}
    [result] = RspValuation.apply([changed], [report([hsn(100, 14.28, 14.29)])])
    assert result["tax_valuation"]["status"] == "unresolved"
    assert hd(result["line_items"])["cgst_amount"] == 15.0
    assert hd(result["line_items"])["tax_amount_basis"] == "reviewer_entered"
  end

  test "same totals in another upload cannot justify tax for this upload" do
    sale = invoice("B2B", "A", 100, 128.57)
    sale = Map.put(sale, "return_report_dump_id", 12)
    report = report([hsn(100, 14.28, 14.29)]) |> Map.put("dump_id", 99)

    [unchanged] = RspValuation.apply([sale], [report])
    refute unchanged["tax_valuation"]
    assert hd(unchanged["line_items"])["cgst_amount"] == 20.0
  end

  test "reset preserves a reviewer tax edit made after a derived view" do
    sale = invoice("B2B", "A", 100, 128.57)
    [derived] = RspValuation.apply([sale], [report([hsn(100, 14.28, 14.29)])])
    [line] = derived["line_items"]
    edited = %{derived | "line_items" => [%{line | "cgst_amount" => 14.0}]}

    reset = RspValuation.reset(edited)
    assert hd(reset["line_items"])["cgst_amount"] == 14.0
    assert hd(reset["line_items"])["sgst_amount"] == 20.0
    refute reset["tax_valuation"]
    assert hd(reset["line_items"])["tax_amount_basis"] == nil
  end

  test "a corrected tax amount retains reviewer provenance before replay" do
    sale = invoice("B2B", "A", 100, 128.57)
    [derived] = RspValuation.apply([sale], [report([hsn(100, 14.28, 14.29)])])
    corrected = Invoice.apply_correction(derived, "line_items[0].cgst_amount", 14.28)

    assert hd(corrected["line_items"])["corrected_tax_fields"] == ["cgst_amount"]
    reset = RspValuation.reset(corrected)
    assert hd(reset["line_items"])["cgst_amount"] == 14.28

    [unresolved] = RspValuation.apply([corrected], [report([hsn(100, 14.28, 14.29)])])
    assert unresolved["tax_valuation"]["status"] == "unresolved"
    assert hd(unresolved["line_items"])["cgst_amount"] == 14.28
    assert hd(unresolved["line_items"])["sgst_amount"] == nil
  end

  test "editing one head on an unresolved row does not restore its synthetic other head" do
    sale = invoice("B2B", "A", 100, 128.57)
    [unresolved] = RspValuation.apply([sale], [report([hsn(100, 0, 0)])])
    assert hd(unresolved["line_items"])["sgst_amount"] == nil

    corrected = Invoice.apply_correction(unresolved, "line_items[0].cgst_amount", 14.28)
    [replayed] = RspValuation.apply([corrected], [report([hsn(100, 0, 0)])])
    assert replayed["tax_valuation"]["status"] == "unresolved"
    assert hd(replayed["line_items"])["cgst_amount"] == 14.28
    assert hd(replayed["line_items"])["sgst_amount"] == nil
  end

  test "a valid reviewed tax split survives recalculation and retains its origin" do
    sale = invoice("B2B", "A", 100, 128.57)
    [line] = sale["line_items"]
    changed = %{sale | "line_items" => [%{line | "cgst_amount" => 14.29, "sgst_amount" => 14.28}]}
    [result] = RspValuation.apply([changed], [report([hsn(100, 14.29, 14.28)])])

    assert result["tax_valuation"]["status"] == "derived"
    assert result["tax_valuation"]["method"] == "reviewer_entered"
    assert hd(result["line_items"])["cgst_amount"] == 14.29
  end

  defp invoice(section, number, taxable, value) do
    source = %{
      "rate" => 40.0,
      "date" => "2026-08-01",
      "value" => value,
      "txval" => taxable,
      "camt" => taxable * 0.2,
      "samt" => taxable * 0.2,
      "iamt" => 0.0,
      "csamt" => 0.0,
      "pos" => "33-Tamil Nadu",
      "invoice_type" => "R",
      "etin" => nil
    }

    %{
      "id" => number,
      "invoice_number" => number,
      "document_type" => if(section == "CDNR", do: "credit_note", else: "invoice"),
      "invoice_date" => ~D[2026-08-01],
      "seller_gstin" => "33ABCFR6054J1Z5",
      "place_of_supply" => "33",
      "reverse_charge" => false,
      "printed_grand_total" => value,
      "return_report_section" => section,
      "return_report_values" => [source],
      "line_items" => [
        %{
          "taxable_value" => taxable,
          "cgst_rate" => 20.0,
          "sgst_rate" => 20.0,
          "igst_rate" => nil,
          "cgst_amount" => taxable * 0.2,
          "sgst_amount" => taxable * 0.2,
          "igst_amount" => 0.0
        }
      ]
    }
  end

  defp hsn(taxable, cgst, sgst),
    do: %{
      "section" => "hsn_b2b",
      "source_filename" => "HSN(B2B).xlsx",
      "values" => %{
        "hsn_sc" => "24022030",
        "rate" => 40.0,
        "txval" => taxable,
        "camt" => cgst,
        "samt" => sgst,
        "iamt" => 0.0,
        "csamt" => 0.0
      }
    }

  defp report(rows), do: %{"format" => "standard_gstr1_sections", "rows" => rows}
end
