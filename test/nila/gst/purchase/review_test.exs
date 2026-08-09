defmodule Nila.Gst.Purchase.ReviewTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Purchase.{Groups, Reconciliation, Review, Workings}

  @gstin "33AAACS1234A1Z9"

  test "Needs you skips settled matches while All retains register order and progress" do
    open_books = books("open", "BOOK-1")
    clean_books = books("clean", "CLEAN-1")
    open_2b = gstr2b("PORTAL-1")
    clean_2b = gstr2b("CLEAN-1")
    recon = Reconciliation.reconcile([open_books, clean_books], [open_2b, clean_2b])
    workings = workings(recon)
    review = Review.project(workings, month: %{client_id: 1, period: "2026-08"})

    assert Enum.map(review.needs_you, & &1.member_ids) == [["open"]]
    assert length(review.all) == 2
    assert review.progress == %{done: 0, total: 1}

    open = Review.lookup(review.all, "open")
    assert Review.next(review, :needs_you, open.id) == nil
    assert Review.lookup(review.all, "clean").resolved
  end

  test "missing bills are counted separately and skipped by decision Next" do
    first = books("first", "BOOK-1")
    second = books("second", "BOOK-2")
    missing = Map.put(gstr2b("MISSING"), "vendor_gstin", "27AAPFU0939F1ZV")
    recon = Reconciliation.reconcile([first, second], [missing])
    review = Review.project(workings(recon), month: %{client_id: 1, period: "2026-08"})
    [first_item, second_item] = Enum.filter(review.needs_you, &(&1.kind == :books))

    assert review.missing_count == 1
    assert Review.next(review, :needs_you, first_item.id).id == second_item.id
  end

  test "ITC treatment and document possession are first-class decisions" do
    recon = Reconciliation.reconcile([], [gstr2b("CLEAN-1")])
    document_case = document_case("CLEAN-1")

    workings =
      recon
      |> workings()
      |> Map.put(:itc, %{
        "blocks" => [
          %{
            "block_id" => "duplicate|clean",
            "code" => "duplicate_invoice",
            "section" => "s.17(5)",
            "vendor" => "Vendor",
            "invoice_number" => "CLEAN-1",
            "tax_paise" => 18_000,
            "reason" => "The bill appears twice.",
            "state" => "recommended"
          }
        ]
      })
      |> Map.put(:case_lines, [document_case])
      |> Map.put(:document_cases, [document_case])

    review = Review.project(workings, month: %{client_id: 1, period: "2026-08"})

    assert review.progress == %{done: 0, total: 2}
    assert MapSet.new(review.needs_you, & &1.kind) == MapSet.new([:itc, :gstr2b])
    assert Review.open_decision_count(workings) == 2
  end

  test "group evidence gap is taken from any member, not only the first" do
    first = books("a", "SAME", %{"images" => []})
    second = books("d9_b", "SAME", %{"images" => []})
    counterpart = gstr2b("SAME")
    recon = Reconciliation.reconcile([first, second], [counterpart])

    review =
      Review.project(workings(recon),
        month: %{client_id: 1, period: "2026-08"},
        evidence_gaps: %{9 => %{source: "packet.pdf", original_url: "/original"}}
      )

    assert [item] = review.needs_you
    assert item.evidence_gap.source == "packet.pdf"
  end

  defp workings(recon) do
    %{
      recon: recon,
      baseline: Workings.materialize(recon, []),
      decisions: %{},
      accepted_reasons: %{},
      gstr2b_decisions: %{},
      groups: Groups.build(recon),
      rows: Workings.books_invoices(recon),
      itc: %{"blocks" => []},
      document_attestation: nil,
      case_lines: [],
      document_cases: []
    }
  end

  defp document_case(number) do
    %{
      case_id: 1,
      source_refs: %{"gstr2b" => %{"2026-08" => Reconciliation.gstr2b_ref(gstr2b(number))}},
      document_state: "unknown",
      asked_at: nil
    }
  end

  defp books(id, number, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "vendor_name" => "Vendor",
        "vendor_gstin" => @gstin,
        "invoice_number" => number,
        "invoice_date" => ~D[2026-08-05],
        "taxable_paise" => 100_000,
        "tax_paise" => %{"cgst" => 9_000, "sgst" => 9_000, "igst" => 0},
        "total_paise" => 118_000,
        "images" => []
      },
      attrs
    )
  end

  defp gstr2b(number) do
    %{
      "vendor_name" => "VENDOR",
      "vendor_gstin" => @gstin,
      "invoice_number" => number,
      "invoice_date" => ~D[2026-08-05],
      "taxable_paise" => 100_000,
      "tax_paise" => %{"cgst" => 9_000, "sgst" => 9_000, "igst" => 0},
      "total_paise" => 118_000
    }
  end
end
