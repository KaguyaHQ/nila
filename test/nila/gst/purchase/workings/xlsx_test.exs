defmodule Nila.Gst.Purchase.Workings.XlsxTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Purchase.{Reconciliation, Register, Review, Workings}
  alias Nila.Gst.Purchase.Workings.Xlsx

  test "treatment sheet shows four heads and carry without changing source totals" do
    case_line = %{
      case_id: 7,
      document_type: "invoice",
      vendor: "Supplier",
      supplier_gstin: "33AAACS1234A1Z9",
      invoice_number: "INV-7",
      origin_period: "2026-07",
      treatment: "split",
      later_reason: "review_pending",
      exclude_reason: "personal",
      treatment_note: "Client confirmed",
      outstanding_heads: %{"cgst" => 1_000, "sgst" => 1_000, "igst" => 100, "cess" => 50},
      treatment_heads: %{
        "claim" => %{"cgst" => 500, "sgst" => 0, "igst" => 100, "cess" => 50},
        "later" => %{"cgst" => 500, "sgst" => 500, "igst" => 0, "cess" => 0},
        "exclude" => %{"cgst" => 0, "sgst" => 500, "igst" => 0, "cess" => 0}
      },
      source_refs: %{"gstr2b" => %{"2026-07" => "2B-7"}}
    }

    workings = %{
      recon: %{
        "matched" => [],
        "value_mismatch" => [],
        "in_2b_not_books" => [],
        "in_books_not_2b" => [],
        "needs_human" => []
      },
      rows: [],
      case_lines: [case_line],
      itc: %{
        "reported_2b_paise" => 0,
        "opening_outstanding_paise" => 2_150,
        "current_claim_paise" => 650,
        "later_paise" => 1_000,
        "excluded_paise" => 500,
        "pending_paise" => 0,
        "closing_outstanding_paise" => 1_000,
        "current_claim_heads" => case_line.treatment_heads["claim"],
        "blocks" => []
      }
    }

    assert {:ok, bytes} =
             Xlsx.build(workings, %{name: "Client", gstin: "33AEWPH4158J1Z3"}, "2026-08",
               review: %{all: []}
             )

    {:ok, files} = :zip.unzip(bytes, [:memory])
    files = Map.new(files, fn {path, data} -> {to_string(path), data} end)
    assert files["xl/sharedStrings.xml"] =~ "2026-07"
    assert files["xl/sharedStrings.xml"] =~ "Claim this month CESS"
    assert files["xl/worksheets/sheet1.xml"] =~ "B6-SUM(B7:B10)"
    assert numeric_cell(files, "xl/worksheets/sheet1.xml", "B5") == 0.0
    assert numeric_cell(files, "xl/worksheets/sheet1.xml", "B7") == 6.5
    assert numeric_cell(files, "xl/worksheets/sheet6.xml", "R5") == 0.5
  end

  test "retains source evidence, distinct portal amounts, decisions and the ITC arithmetic control" do
    books = %{
      "id" => "books-1",
      "vendor_name" => "Supplier",
      "vendor_gstin" => "33AAACS1234A1Z9",
      "invoice_number" => "=1+1",
      "invoice_date" => "2026-08-05",
      "taxable_paise" => 100_000,
      "tax_paise" => %{"cgst" => 9_000, "sgst" => 9_000, "igst" => 0},
      "total_paise" => 118_000,
      "source_sheet" => "August purchases",
      "source_rows" => [7, 8],
      "images" => []
    }

    portal = %{books | "taxable_paise" => 110_000, "total_paise" => 128_000}
    recon = Reconciliation.reconcile([books], [portal])
    rows = Register.rows([books], recon, %{})

    workings = %{
      recon: recon,
      baseline: recon,
      groups: Nila.Gst.Purchase.Groups.build(recon),
      rows: rows,
      decisions: %{},
      accepted_reasons: %{},
      gstr2b_decisions: %{},
      case_lines: [],
      itc: %{
        "reported_2b_paise" => 18_000,
        "claimable_paise" => 18_000,
        "credit_note_reversal_applied_paise" => 0,
        "pending_decision_paise" => 0,
        "blocked_in_ceiling_paise" => 0,
        "blocks" => []
      }
    }

    review = Review.project(workings, month: %{client_id: 1, period: "2026-08"})

    assert {:ok, bytes} =
             Xlsx.build(workings, %{name: "Client", gstin: "33AEWPH4158J1Z3"}, "2026-08",
               review: review
             )

    {:ok, files} = :zip.unzip(bytes, [:memory])
    files = Map.new(files, fn {path, data} -> {to_string(path), data} end)
    strings = files["xl/sharedStrings.xml"]
    assert strings =~ "August purchases"
    assert strings =~ "7, 8"
    assert strings =~ "=1+1"
    assert strings =~ "value_mismatch"
    assert strings =~ "not filing approval"
    assert files["xl/worksheets/sheet1.xml"] =~ "B6-SUM(B7:B10)"
    assert files["xl/worksheets/sheet2.xml"] =~ "<v>1000</v>"
    assert files["xl/worksheets/sheet3.xml"] =~ "<v>1100</v>"
    refute files["xl/worksheets/sheet2.xml"] =~ "<f>1+1</f>"
    assert shared_cell(files, "xl/worksheets/sheet4.xml", "F5") == "Needs review"
    assert length(Workings.gstr2b_invoices(recon)) == 1

    # Confirming a proposed pairing changes the effective bucket but retains
    # the original invoice-number question as the review item's type.
    baseline = %{
      "needs_human" => [
        %{
          "books" => books,
          "candidates" => [portal],
          "reason" => %{"code" => "invoice_number_mismatch", "message" => "Numbers differ"}
        }
      ]
    }

    confirmed = %{workings | baseline: baseline, decisions: %{books["id"] => "confirm_pair"}}
    confirmed_review = Review.project(confirmed, month: %{client_id: 1, period: "2026-08"})
    assert [%{type: "invoice_number_mismatch", resolved: true}] = confirmed_review.all

    assert {:ok, confirmed_bytes} =
             Xlsx.build(confirmed, %{name: "Client", gstin: "33AEWPH4158J1Z3"}, "2026-08",
               review: confirmed_review
             )

    {:ok, confirmed_files} = :zip.unzip(confirmed_bytes, [:memory])
    confirmed_files = Map.new(confirmed_files, fn {path, data} -> {to_string(path), data} end)
    assert shared_cell(confirmed_files, "xl/worksheets/sheet4.xml", "F5") == "Needs review"

    matched = Reconciliation.reconcile([books], [books])
    flag = %{"code" => "missing_hsn_sac", "reason" => "HSN/SAC missing"}
    flagged_rows = Register.rows([books], matched, %{books["id"] => [flag]})

    workings = %{
      workings
      | recon: matched,
        baseline: matched,
        groups: Nila.Gst.Purchase.Groups.build(matched),
        rows: flagged_rows
    }

    review = Review.project(workings, month: %{client_id: 1, period: "2026-08"})

    assert {:ok, flagged_bytes} =
             Xlsx.build(workings, %{name: "Client", gstin: "33AEWPH4158J1Z3"}, "2026-08",
               review: review
             )

    {:ok, flagged_files} = :zip.unzip(flagged_bytes, [:memory])
    flagged_files = Map.new(flagged_files, fn {path, data} -> {to_string(path), data} end)
    assert shared_cell(flagged_files, "xl/worksheets/sheet4.xml", "F5") == "Needs review"
    assert flagged_files["xl/sharedStrings.xml"] =~ "HSN/SAC missing"
  end

  defp shared_cell(files, sheet, address) do
    [_, index] = Regex.run(~r/<c r="#{address}"[^>]*><v>(\d+)<\/v><\/c>/, files[sheet])
    texts = Regex.scan(~r/<si><t[^>]*>(.*?)<\/t><\/si>/s, files["xl/sharedStrings.xml"])
    texts |> Enum.at(String.to_integer(index)) |> Enum.at(1)
  end

  defp numeric_cell(files, sheet, address) do
    [_, value] = Regex.run(~r/<c r="#{address}"[^>]*><v>([^<]+)<\/v><\/c>/, files[sheet])
    {number, ""} = Float.parse(value)
    number
  end
end
