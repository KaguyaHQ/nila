defmodule Nila.Eval.ReportTest do
  use ExUnit.Case, async: true

  alias Nila.Eval.Report

  defp row(overrides) do
    Map.merge(
      %{
        "scope" => "invoice_item",
        "key" => "33AABCP9487A1ZG|1|18",
        "field" => "txval",
        "extracted" => nil,
        "derived" => 900,
        "filed" => 1000,
        "match" => false,
        "image" => nil,
        "verdict" => nil,
        "bucket" => nil
      },
      overrides
    )
  end

  defp month(overrides) do
    rows = Map.get(overrides, :rows, [row(%{})])
    mismatches = Enum.reject(rows, & &1["match"])

    Map.merge(
      %{
        client: "caltech",
        period: "2025-11",
        rows: rows,
        mismatches: mismatches,
        by_invoice: Report.by_invoice(mismatches),
        auditor_rows: [],
        adjudicated_count: 0,
        raw: %{"score" => 69.52, "matches" => 276, "total" => 397},
        adjusted: nil,
        reviewed: nil,
        policy: Nila.Eval.Gstr1Diff.policy(),
        provenance: %{
          "run_id" => "test-run",
          "extractor" => "TestExtractor",
          "model" => "test-model",
          "prompt_fingerprint" => "abcdef0123456789",
          "scored_at" => "2026-07-30T00:00:00Z"
        }
      },
      overrides
    )
  end

  describe "by_invoice/1" do
    test "groups by invoice and puts the worst offenders first" do
      rows = [
        row(%{"key" => "a|1|18"}),
        row(%{"key" => "b|2|18", "field" => "txval"}),
        row(%{"key" => "b|2|18", "field" => "camt"}),
        row(%{"key" => "b|2|18", "field" => "samt"})
      ]

      assert [{"b|2|18", three}, {"a|1|18", one}] = Report.by_invoice(rows)
      assert length(three) == 3
      assert length(one) == 1
    end
  end

  describe "render/1" do
    test "leads with provenance so a score is never unattributable" do
      body = Report.render(month(%{}))

      assert body =~ "TestExtractor"
      assert body =~ "test-model"
      assert body =~ "abcdef012345"
    end

    test "unscored legs say why rather than repeating the raw number" do
      body = Report.render(month(%{}))

      assert body =~ "_unadjudicated_"
      assert body =~ "_not applicable_"
      refute body =~ "| adjusted | 69.52%"
    end

    test "names an invoice absent from the filed return instead of listing its fields as wrong" do
      rows = [row(%{"filed" => nil}), row(%{"field" => "camt", "filed" => nil})]

      assert Report.render(month(%{rows: rows})) =~ "not in the filed return"
    end

    test "names an invoice we failed to produce" do
      rows = [row(%{"derived" => nil}), row(%{"field" => "camt", "derived" => nil})]

      assert Report.render(month(%{rows: rows})) =~ "we produced nothing"
    end

    test "renders money without scientific notation" do
      body = Report.render(month(%{rows: [row(%{"derived" => 9.5e3, "filed" => 9500.5})]}))

      assert body =~ "9500"
      assert body =~ "9500.50"
      refute body =~ "e3"
    end

    test "points at the scanned page an invoice was read from" do
      body = Report.render(month(%{rows: [row(%{"image" => "page_07.png"})]}))

      assert body =~ "page_07.png"
    end

    test "the confession sheet lists only AUDITOR rows, with the reason" do
      auditor = row(%{"verdict" => "AUDITOR"})

      body =
        Report.render(
          month(%{
            rows: [auditor],
            auditor_rows: [{auditor, %{"verdict" => "AUDITOR", "note" => "they rounded"}}]
          })
        )

      assert body =~ "Where we differ from the filed return"
      assert body =~ "they rounded"
    end

    test "records the diff policy that produced the score" do
      body = Report.render(month(%{}))

      assert body =~ "tolerance 0.01"
      assert body =~ "`chksum`"
    end

    test "a clean month says so rather than printing an empty table" do
      body = Report.render(month(%{rows: [row(%{"match" => true})]}))

      assert body =~ "every compared field agrees"
    end
  end

  describe "write!/2" do
    test "writes one JSON object per compared field alongside the markdown" do
      dir = Path.join(System.tmp_dir!(), "report_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      path = Report.write!(dir, month(%{}))

      assert Path.basename(path) == "report.md"

      lines =
        dir |> Path.join("fields.jsonl") |> File.read!() |> String.split("\n", trim: true)

      assert length(lines) == 1
      assert %{"field" => "txval", "filed" => 1000} = Jason.decode!(hd(lines))
    end
  end
end
