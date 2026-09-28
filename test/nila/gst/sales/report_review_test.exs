defmodule Nila.Gst.Sales.ReportReviewTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Sales.{Gstr1, Workings, ReportReview}

  test "missing summary fields are one task per row and clean rows need no task" do
    row = %{
      "sheet" => "HSNB2B",
      "section" => "hsn_b2b",
      "row" => 2,
      "values" => %{
        "hsn_sc" => "998599",
        "uqc" => "NA",
        "qty" => 0,
        "rate" => nil,
        "txval" => 0,
        "iamt" => 0,
        "camt" => 0,
        "samt" => 0,
        "csamt" => 0
      }
    }

    report = %{"dump_id" => 1, "filename" => "report.xls", "rows" => [row]}

    working =
      Workings.materialize([], [], Gstr1.production_header("33AEWPH4158J1Z3", "2026-08"), [],
        return_reports: [report]
      )

    assert [%{"kind" => "row", "fields" => ["rate"]}] = ReportReview.build(working)
    [task] = ReportReview.build(working)
    assert byte_size(task["id"]) < 60

    assert task["id"] !=
             hd(ReportReview.build(%{working | return_reports: [Map.put(report, "dump_id", 2)]}))[
               "id"
             ]

    fixed = put_in(report, ["rows"], [put_in(row, ["values", "rate"], 18)])
    assert [] == ReportReview.build(%{working | return_reports: [fixed]})
  end

  test "note group selection stays stable when one note leaves the group" do
    notes =
      for id <- ~w(note-a note-b) do
        %{
          "id" => id,
          "invoice_number" => id,
          "invoice_date" => "2026-08-01",
          "seller_gstin" => "33AEWPH4158J1Z3",
          "return_report_dump_id" => 1,
          "return_report_section" => "CDNUR",
          "document_type" => "credit_note",
          "place_of_supply" => "33",
          "original_sale_category" => "b2cl",
          "recipient_registration" => "unregistered",
          "line_items" => []
        }
      end

    report = %{
      "dump_id" => 1,
      "filename" => "notes.xlsx",
      "rows" => [],
      "basis" => "unchanged-source"
    }

    header = Gstr1.production_header("33AEWPH4158J1Z3", "2026-08")

    build = fn invoices ->
      Workings.materialize(invoices, [], header, [], return_reports: [report])
      |> ReportReview.build()
      |> Enum.find(&(&1["kind"] == "notes"))
    end

    before = build.(notes)

    after_correction =
      build.([Map.put(hd(notes), "original_sale_category", "b2cs"), List.last(notes)])

    assert before["source_ids"] == ~w(note-a note-b)
    assert after_correction["source_ids"] == ["note-b"]
    assert before["id"] == after_correction["id"]
    assert before["basis"] == after_correction["basis"]
  end

  test "report client names are not treated as printed seller names" do
    invoice = %{
      "id" => "x",
      "seller_name" => "Wrong client label",
      "seller_gstin" => "33AEWPH4158J1Z3",
      "return_report_section" => "B2B",
      "line_items" => []
    }

    working =
      Workings.materialize([invoice], [], Gstr1.production_header("33AEWPH4158J1Z3", "2026-08"))

    assert hd(working.source_invoices)["seller_name"] == nil
  end

  test "same sheet and row in different files remain separate correction tasks" do
    rows =
      for {filename, section} <- [{"HSN(B2B).xlsx", "hsn_b2b"}, {"HSN(B2C).xlsx", "hsn_b2c"}] do
        %{
          "source_filename" => filename,
          "sheet" => "HSN",
          "row" => 2,
          "section" => section,
          "values" => %{
            "hsn_sc" => "998599",
            "uqc" => "NA",
            "qty" => 0,
            "rate" => nil,
            "txval" => 100,
            "iamt" => 0,
            "camt" => 9,
            "samt" => 9,
            "csamt" => 0
          }
        }
      end

    report = %{"dump_id" => 1, "filename" => "2 files", "rows" => rows}

    working =
      Workings.materialize([], [], Gstr1.production_header("33AEWPH4158J1Z3", "2026-08"), [],
        return_reports: [report]
      )

    tasks = ReportReview.build(working)
    assert length(tasks) == 2
    assert tasks |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 2
    assert Enum.map(tasks, & &1["source_filename"]) == ["HSN(B2B).xlsx", "HSN(B2C).xlsx"]
  end
end
