defmodule Nila.Gst.Sales.ReturnSourcesTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Sales.{ReturnSources, Gstr1, Workings}

  defp row(sheet, values, number \\ 2),
    do: %{
      "sheet" => sheet,
      "section" => %{"B2CS" => "b2cs", "HSNB2CS" => "hsn_b2c", "Docs" => "doc_issue"}[sheet],
      "row" => number,
      "values" => values
    }

  defp report(rows, extra \\ %{}),
    do: Map.merge(%{"dump_id" => 1, "filename" => "sales.xls", "rows" => rows}, extra)

  defp summary do
    %{
      "seller_gstin" => "33AEWPH4158J1Z3",
      "rate" => 18.0,
      "txval" => 100.0,
      "iamt" => 0.0,
      "camt" => 9.0,
      "samt" => 9.0,
      "csamt" => 0.0,
      "type" => "OE",
      "supply" => "INTRA",
      "pos" => "33",
      "hsn_sc" => "998599",
      "desc" => "Services",
      "qty" => 1.0,
      "uqc" => "NA"
    }
  end

  defp projection(invoices \\ []),
    do: Gstr1.project(invoices, Gstr1.production_header("33AEWPH4158J1Z3", "2026-08"))

  test "supplied B2CS and HSN totals remain summaries without manufactured invoices" do
    r = report([row("B2CS", summary()), row("HSNB2CS", summary())])
    {result, issues, rows} = ReturnSources.apply(projection(), [], [r])
    assert result.derived["b2cs"] |> hd() |> Map.fetch!("txval") == 100.0
    assert result.derived["hsn"]["hsn_b2c"] |> hd() |> Map.fetch!("hsn_sc") == "998599"
    assert result.contributions == %{}
    assert issues == []
    assert Enum.all?(rows, &(&1["dump_id"] == 1 and &1["row"] == 2))
  end

  test "changing a B2CS state recalculates supply type and exposes the old tax split" do
    source = row("B2CS", %{summary() | "pos" => "29", "supply" => "INTRA"})
    {result, issues, _} = ReturnSources.apply(projection(), [], [report([source])])

    assert [%{"pos" => "29", "sply_ty" => "INTER"}] =
             Enum.map(result.derived["b2cs"], &Map.take(&1, ["pos", "sply_ty"]))

    assert Enum.any?(issues, &String.contains?(&1["message"], "Tax amounts do not match"))
    refute Workings.reviewable?(issues)
  end

  test "invalid supplied HSN rates and codes stay blocking after import" do
    for changes <- [
          %{"rate" => 180.0},
          %{"rate" => -18.0},
          %{"hsn_sc" => "bad"},
          %{"uqc" => "???"}
        ] do
      source = row("HSNB2CS", Map.merge(summary(), changes))
      {_result, issues, _} = ReturnSources.apply(projection(), [], [report([source])])
      assert Enum.any?(issues, &String.contains?(&1["message"], "invalid"))
      refute Workings.reviewable?(issues)
    end
  end

  test "source HSN disagreements block the return without forcing totals to match" do
    r = report([row("B2CS", summary()), row("HSNB2CS", Map.put(summary(), "txval", 90.0))])
    {result, issues, _} = ReturnSources.apply(projection(), [], [r])
    assert Enum.any?(issues, &String.contains?(&1["message"], "differ"))
    refute Workings.reviewable?(issues)
    assert hd(result.derived["hsn"]["hsn_b2c"])["txval"] == 90.0
  end

  test "standard section packets compare only HSN sections they supplied" do
    b2cs = row("B2CS", summary())
    hsn = row("HSNB2CS", Map.put(summary(), "txval", 90.0))
    standard = report([b2cs, hsn], %{"format" => "standard_gstr1_sections"})

    {_result, issues, _} = ReturnSources.apply(projection(), [], [standard])

    assert Enum.any?(
             issues,
             &String.contains?(&1["message"], "hsn_b2c txval: supplied HSN totals differ")
           )

    refute Enum.any?(issues, &String.contains?(&1["message"], "hsn_b2b"))

    absent_hsn = report([b2cs], %{"format" => "standard_gstr1_sections"})
    {_result, issues, _} = ReturnSources.apply(projection(), [], [absent_hsn])

    assert Enum.any?(issues, &(&1["target"] == "return_report:hsn_missing:1:hsn_b2c"))
    refute Enum.any?(issues, &String.contains?(&1["message"], "supplied HSN totals differ"))
  end

  test "the older section report still checks both HSN groups" do
    {_result, issues, _} =
      ReturnSources.apply(projection(), [], [report([row("B2CS", summary())])])

    assert Enum.any?(
             issues,
             &String.contains?(&1["message"], "hsn_b2c txval: supplied HSN totals differ")
           )
  end

  test "the shared return pipeline is independent of source sheet names and positions" do
    rows = [row("B2CS", summary()), row("HSNB2CS", summary())]

    other_layout =
      rows
      |> Enum.with_index(17)
      |> Enum.map(fn {r, n} -> %{r | "sheet" => "ERP output #{n}", "row" => n} end)

    {first, _, _} = ReturnSources.apply(projection(), [], [report(rows)])
    {second, _, evidence} = ReturnSources.apply(projection(), [], [report(other_layout)])
    assert first.derived["b2cs"] == second.derived["b2cs"]

    assert Map.delete(hd(first.derived["hsn"]["hsn_b2c"]), "num") ==
             Map.delete(hd(second.derived["hsn"]["hsn_b2c"]), "num")

    assert hd(evidence)["sheet"] == "ERP output 17"
  end

  test "unknown document labels stay visible and block export" do
    r =
      report([
        row("Docs", %{
          "nature" => "Claim Tax",
          "from" => "A1",
          "to" => "A1",
          "totnum" => 1,
          "cancel" => 0,
          "net_issue" => 1
        })
      ])

    {result, issues, _} = ReturnSources.apply(projection(), [], [r])
    assert result.derived["doc_issue"]["doc_det"] == []
    assert Enum.any?(issues, &String.contains?(&1["message"], "Claim Tax"))
  end

  test "a note marked B2CL needs explicit POS and a consistent original category" do
    invoice = %{
      "id" => "n1",
      "seller_gstin" => "33AEWPH4158J1Z3",
      "return_report_section" => "CDNUR",
      "original_sale_category" => "b2cl"
    }

    assert [%{"fields" => ["place_of_supply"]}] = ReturnSources.invoice_checks([invoice])

    assert [%{"fields" => ["original_sale_category"]}] =
             ReturnSources.invoice_checks([Map.put(invoice, "place_of_supply", "33")])

    assert [] =
             ReturnSources.invoice_checks([
               Map.merge(invoice, %{"place_of_supply" => "33", "original_sale_category" => "b2cs"})
             ])
  end

  test "document series share one category and export integer counts without adding invoices" do
    values = %{
      "doc_num" => 1,
      "from" => "A1",
      "to" => "A1",
      "totnum" => 1.0,
      "cancel" => 0.0,
      "net_issue" => 1.0
    }

    rows = [
      row("Docs", values),
      row("Docs", Map.merge(values, %{"from" => "B1", "to" => "B1"}), 4)
    ]

    {result, issues, _} = ReturnSources.apply(projection(), [], [report(rows)])
    assert issues == []
    assert [%{"doc_num" => 1, "docs" => docs}] = result.derived["doc_issue"]["doc_det"]
    assert Enum.map(docs, & &1["num"]) == [1, 2]
    assert Enum.all?(docs, &is_integer(&1["totnum"]))
    assert result.derived["b2b"] == []
  end

  test "B2CS notes are deducted once whether the supplied total is gross or already net" do
    note =
      Nila.Gst.Extraction.Sales.Normalizer.normalize(%{
        "data" => %{
          "document_type" => "credit_note",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "unregistered",
          "original_sale_category" => "b2cs",
          "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{},
          "invoice_number" => "CN1",
          "invoice_date" => "2026-08-01",
          "place_of_supply" => "33",
          "printed_grand_total" => 11.8,
          "reverse_charge" => false,
          "line_items" => [
            %{
              "printed_taxable_value" => 10,
              "cgst_rate" => 9,
              "sgst_rate" => 9,
              "cgst_amount" => 0.9,
              "sgst_amount" => 0.9,
              "igst_amount" => 0
            }
          ]
        }
      })
      |> Map.merge(%{
        "id" => "note",
        "return_report_dump_id" => 1,
        "return_report_section" => "CDNUR"
      })

    net = Map.merge(summary(), %{"txval" => 90, "camt" => 8.1, "samt" => 8.1})

    for {before_notes, source} <- [{true, summary()}, {false, net}] do
      r =
        report([row("B2CS", source), row("HSNB2CS", net)], %{"b2cs_before_notes" => before_notes})

      {result, issues, _} = ReturnSources.apply(projection([note]), [note], [r])
      assert issues == []
      assert [%{"txval" => 90.0, "camt" => 8.1, "samt" => 8.1}] = result.derived["b2cs"]
      assert result.derived["cdnur"] == []
    end
  end

  test "only invoices covered by supplied report summaries lose missing-HSN checks" do
    issue = %{"source_id" => "n1", "code" => "missing_hsn_sac"}
    invoice = %{"id" => "n1", "return_report_section" => "B2B", "return_report_dump_id" => 1}
    assert [^issue] = ReturnSources.invoice_issues([issue], [invoice], [])
    assert [] = ReturnSources.invoice_issues([issue], [invoice], [report([])])
    assert [^issue] = ReturnSources.invoice_issues([issue], [%{"id" => "n1"}], [report([])])
  end
end
