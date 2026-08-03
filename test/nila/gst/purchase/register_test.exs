defmodule Nila.Gst.Purchase.RegisterTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Purchase.{Groups, Reconciliation, Register}

  describe "stats/1 and need_decision/1" do
    test "count every bucket, including 2B-only rows, and subtract matches and accepted unmatched" do
      summary = %{
        "buckets" => %{
          "matched" => 3,
          "needs_human" => 2,
          "in_books_not_2b" => 4,
          "in_2b_not_books" => 5
        },
        "accepted_unmatched" => 2,
        "taxable_paise" => 500_000,
        "total_tax_paise" => 160_000,
        "matched_tax_paise" => 90_000,
        "open_tax_paise" => 45_000
      }

      assert Register.stats(summary) == %{
               rows: 14,
               invoices: 9,
               gstr2b_only: 5,
               matched: 3,
               open: 9,
               need_decision: 4,
               decision_rows: 4,
               awaiting_bills: 5,
               value_disputes: 0,
               taxable_paise: 500_000,
               total_tax_paise: 160_000,
               matched_tax_paise: 90_000,
               open_tax_paise: 45_000,
               settled_tax_paise: 115_000,
               awaiting_bills_tax_paise: 0,
               value_dispute_tax_paise: 0,
               decision_tax_paise: 45_000,
               decision_row_tax_paise: 45_000,
               unreported_by_vendor_tax_paise: 0,
               unreported_by_vendor_known?: false,
               open_money_split_known?: false,
               itc_money_known?: true
             }

      # The 5 rows the portal reported and nobody supplied are a chase, not
      # judgements: there is no bill to open and nothing to compare.
      assert Register.need_decision(summary) == 4
      assert Register.open(summary) == 9
    end

    # `matched` and `open` are not complements: audited-accepted rows are in
    # neither, so a surface showing those two beside the total teaches a sum
    # that lands ₹25,000 short of the month. `settled` is the exact complement.
    test "settled and open partition the month's ITC exactly" do
      summary = %{
        "total_tax_paise" => 160_000,
        "matched_tax_paise" => 90_000,
        "open_tax_paise" => 45_000
      }

      stats = Register.stats(summary)

      assert stats.settled_tax_paise + stats.open_tax_paise == stats.total_tax_paise
      assert stats.settled_tax_paise > stats.matched_tax_paise
    end

    test "defaults missing counts and money to zero" do
      assert Register.stats(%{}) == %{
               rows: 0,
               invoices: 0,
               gstr2b_only: 0,
               matched: 0,
               open: 0,
               need_decision: 0,
               decision_rows: 0,
               awaiting_bills: 0,
               value_disputes: 0,
               taxable_paise: 0,
               total_tax_paise: 0,
               matched_tax_paise: 0,
               open_tax_paise: 0,
               settled_tax_paise: 0,
               awaiting_bills_tax_paise: 0,
               value_dispute_tax_paise: 0,
               decision_tax_paise: 0,
               decision_row_tax_paise: 0,
               unreported_by_vendor_tax_paise: 0,
               unreported_by_vendor_known?: false,
               open_money_split_known?: true,
               itc_money_known?: true
             }

      summary = %{"buckets" => %{"in_2b_not_books" => 1}}
      assert Register.need_decision(summary) == 0
      assert Register.stats(summary).awaiting_bills == 1
      assert Register.open(summary) == 1
    end

    test "credit the portal never reported is a figure, not a subtraction" do
      # The month's own ITC and the 2B ceiling differ by exactly this, and it had
      # no name: a reader could only find it by subtracting two totals that
      # looked like they should agree. It is also the most actionable number on
      # the page — not claimable this month, and each row is a vendor to chase.
      rows = [
        %{
          "bucket" => "matched",
          "cgst_paise" => 5_000,
          "sgst_paise" => 5_000,
          "igst_paise" => 0,
          "taxable_paise" => 100_000,
          "flags" => []
        },
        %{
          "bucket" => "in_books_not_2b",
          "cgst_paise" => 163,
          "sgst_paise" => 164,
          "igst_paise" => 0,
          "taxable_paise" => 8_000,
          "flags" => []
        },
        # Still hunting for its 2B counterpart: the books claim this credit and
        # no 2B entry backs it yet, so it is unreported for the same reason.
        %{
          "bucket" => "needs_human",
          "cgst_paise" => 200,
          "sgst_paise" => 200,
          "igst_paise" => 0,
          "taxable_paise" => 4_000,
          "flags" => []
        }
      ]

      stats = rows |> Register.summary() |> Register.stats()

      assert stats.unreported_by_vendor_known?
      assert stats.unreported_by_vendor_tax_paise == 727

      # And it closes: the books' ITC less this gap is the 2B ceiling.
      assert stats.total_tax_paise - stats.unreported_by_vendor_tax_paise == 10_000
    end

    test "a snapshot frozen before the gap existed says so rather than reading zero" do
      stats = Register.stats(%{"buckets" => %{"matched" => 1}, "total_tax_paise" => 10_000})

      refute stats.unreported_by_vendor_known?
      assert stats.unreported_by_vendor_tax_paise == 0
    end

    # Every summary written before `total_tax_paise` existed is still on disk.
    # Reading ₹0 there would put a headline like "₹0 of ITC this month, ₹45,000
    # of it riding on 9 decisions" in front of a reviewer, so the old fields
    # stand in. It understates by the accepted rows; it never contradicts.
    test "an older summary falls back to matched + open rather than zero" do
      summary = %{"matched_tax_paise" => 90_000, "open_tax_paise" => 45_000}

      stats = Register.stats(summary)

      assert stats.total_tax_paise == 135_000
      assert stats.itc_money_known?
    end

    # The fallback above has nothing left to fall back to: a snapshot frozen
    # before any of the money existed reads 0 for the whole month, the total and
    # the settled figure alike, beside bucket counts that are real. "₹0 of ITC"
    # above twelve bills is impossible on its face, and stating it teaches a
    # reviewer to distrust every other figure in the panel.
    test "a snapshot frozen before the money existed says so rather than reading zero" do
      stats = Register.stats(%{"buckets" => %{"matched" => 8, "needs_human" => 4}})

      refute stats.itc_money_known?
      assert stats.total_tax_paise == 0
      assert stats.settled_tax_paise == 0
    end

    # Zero is only unsayable when something contradicts it. A register with no
    # rows has no tax to sum, so ₹0 is the answer rather than a guess.
    test "an empty register still states its ITC" do
      assert Register.stats(%{}).itc_money_known?
      assert Register.stats(%{"buckets" => %{}}).itc_money_known?
    end
  end

  describe "summary/1 money" do
    test "open_tax_paise sums exactly the rows need_decision counts" do
      rows = [
        row("a", "matched", nil, 1_000),
        row("b", "needs_human", nil, 2_000),
        row("c", "in_books_not_2b", "await_2b", 4_000),
        row("d", "in_2b_not_books", nil, 8_000)
      ]

      summary = Register.summary(rows)

      # b and d are open; a is matched and c was accepted with an audited reason.
      assert summary["open_tax_paise"] == 10_000
      assert summary["matched_tax_paise"] == 1_000
      assert Register.open(summary) == 2

      # d is 2B-only: its ₹8,000 waits on a document, not on anyone's judgement,
      # so it leaves the decision count and its money with it.
      assert summary["awaiting_bills_tax_paise"] == 8_000
      assert Register.need_decision(summary) == 1
      assert Register.stats(summary).decision_tax_paise == 2_000
      assert Register.stats(summary).awaiting_bills == 1
    end

    # `stats/1` reads aggregates while the surfaces filter rows, so the two can
    # drift. They did: deriving the split as `min(gstr2b_only, open)` counted
    # audited 2B-only rows as bills still to chase and took the difference out of
    # need_decision — with 3 of 5 accepted the page read "5 to collect, 2 to
    # decide" when the truth was 2 and 5, exactly inverted.
    test "FREEZELINKS keeps invoice rows but counts the connected question and tax once" do
      invoice = fn id ->
        %{
          "id" => id,
          "vendor_name" => "Freezelinks",
          "vendor_gstin" => "33AAACS1234A1Z9",
          "invoice_number" => "FREEZE-1",
          "invoice_date" => ~D[2025-10-05],
          "taxable_paise" => 1_000_000,
          "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
          "total_paise" => 1_180_000,
          "pages" => [],
          "images" => []
        }
      end

      counterpart =
        invoice.("ignored")
        |> Map.delete("id")
        |> Map.put("vendor_name", "FREEZELINKS")

      invoices = [invoice.("freezelinks-1"), invoice.("freezelinks-2")]
      recon = Reconciliation.reconcile(invoices, [counterpart])
      groups = Groups.build(recon)
      rows = Register.rows(invoices, recon, %{})
      stats = rows |> Register.summary(groups) |> Register.stats()

      assert length(rows) == 2
      refute Enum.any?(rows, &Map.has_key?(&1, "review_group_key"))
      assert stats.open == 2
      assert stats.decision_rows == 2
      assert stats.need_decision == 1
      assert stats.decision_tax_paise == 180_000
      assert stats.decision_row_tax_paise == 360_000
    end

    test "the count split agrees with the predicates once 2B-only rows are accepted" do
      rows =
        for(i <- 1..3, do: row("a#{i}", "in_2b_not_books", "await_2b", 100)) ++
          for(i <- 1..2, do: row("b#{i}", "in_2b_not_books", nil, 100)) ++
          for(i <- 1..5, do: row("c#{i}", "needs_human", nil, 100))

      stats = rows |> Register.summary() |> Register.stats()

      assert stats.awaiting_bills == Enum.count(rows, &Register.awaiting_bill?/1)
      assert stats.decision_rows == Enum.count(rows, &Register.decision_row?/1)
      assert stats.need_decision == stats.decision_rows
      assert stats.open == Enum.count(rows, &Register.open_row?/1)

      assert stats.awaiting_bills == 2
      assert stats.need_decision == 5
      assert stats.decision_rows + stats.awaiting_bills == stats.open
    end

    # A value mismatch is already paired on GSTIN and invoice number; only the
    # amounts differ. ITC is claimable as reflected in the 2B, so the return
    # takes the 2B figure whether or not anyone opens the row — the delta is a
    # finding and a vendor to chase, not a fork in the filing. It must not block
    # a signature, and it must not stop saying what it found.
    # `decision_tax_paise` is a subtraction, so a snapshot frozen before the two
    # subsets existed yields a plausible positive number rather than an obvious
    # ₹0 — nothing downstream can tell it apart from a month that genuinely has
    # no disputes. The only signal is absent-versus-zero, and `stats/1` collapses
    # it, so the answer has to be taken while the raw summary is still in hand.
    test "a pre-change snapshot reports that its open-money split is unknown" do
      counts = %{
        "buckets" => %{"matched" => 3, "value_mismatch" => 2, "needs_human" => 1},
        "total_tax_paise" => 100_000,
        "matched_tax_paise" => 40_000,
        "open_tax_paise" => 60_000
      }

      legacy = Register.stats(counts)
      modern = Register.stats(Map.put(counts, "value_dispute_tax_paise", 15_000))

      refute legacy.open_money_split_known?
      assert modern.open_money_split_known?

      # Indistinguishable downstream: both look like a month with no disputes,
      # and a `> 0` guard would render the overstatement either way.
      assert legacy.value_dispute_tax_paise == 0
      assert legacy.decision_tax_paise == 60_000
      assert legacy.decision_tax_paise > 0

      # The counts are right retroactively — the buckets always existed.
      assert legacy.value_disputes == 2
      assert legacy.need_decision + legacy.awaiting_bills + legacy.value_disputes == legacy.open

      # No open money at all: nothing to misattribute, so nothing is unknown.
      assert Register.stats(%{}).open_money_split_known?
    end

    test "a value dispute is open money but not an answerable decision" do
      dispute = %{
        "id" => "vm",
        "bucket" => "value_mismatch",
        "accepted_reason" => nil,
        "flags" => [],
        "cgst_paise" => 89_805,
        "sgst_paise" => 89_805,
        "igst_paise" => 0,
        "taxable_paise" => 0,
        "verdict" => "differs from 2B: cgst +₹898.05"
      }

      assert Register.value_dispute?(dispute)
      refute Register.decision_row?(dispute)

      # Still open: the money is not settled and the register keeps reporting it.
      assert Register.open_row?(dispute)

      # Carries no flags, so `annotated_row?` is the only thing making the note
      # speak. Narrowing `open_row?` instead would have silenced exactly the
      # delta this row exists to report.
      assert Register.annotated_row?(dispute)
    end

    test "the open pile splits three ways by who owns the next move" do
      rows = [
        row("matched", "matched", nil, 1_000),
        row("decision", "needs_human", nil, 2_000),
        row("accepted", "in_books_not_2b", "await_2b", 4_000),
        row("chase", "in_2b_not_books", nil, 8_000),
        row("dispute", "value_mismatch", nil, 16_000)
      ]

      stats = rows |> Register.summary() |> Register.stats()

      assert stats.decision_rows == Enum.count(rows, &Register.decision_row?/1)
      assert stats.need_decision == stats.decision_rows
      assert stats.awaiting_bills == Enum.count(rows, &Register.awaiting_bill?/1)
      assert stats.value_disputes == Enum.count(rows, &Register.value_dispute?/1)

      assert stats.decision_rows + stats.awaiting_bills + stats.value_disputes == stats.open

      assert stats.decision_row_tax_paise + stats.awaiting_bills_tax_paise +
               stats.value_dispute_tax_paise == stats.open_tax_paise
    end

    test "the row predicates partition the open pile exactly" do
      rows = [
        row("a", "matched", nil, 1_000),
        row("b", "needs_human", nil, 2_000),
        row("c", "in_books_not_2b", "await_2b", 4_000),
        row("d", "in_2b_not_books", nil, 8_000)
      ]

      open = Enum.filter(rows, &Register.open_row?/1)
      decisions = Enum.filter(rows, &Register.decision_row?/1)
      awaiting = Enum.filter(rows, &Register.awaiting_bill?/1)

      assert length(open) == length(decisions) + length(awaiting)
      assert Enum.map(decisions, & &1["id"]) == ["b"]
      assert Enum.map(awaiting, & &1["id"]) == ["d"]

      # An accepted 2B-only row is settled, not a chase — someone already ruled
      # on it, so it must not reappear as a bill to collect.
      accepted_2b = row("e", "in_2b_not_books", "await_2b", 500)
      refute Register.awaiting_bill?(accepted_2b)
      refute Register.open_row?(accepted_2b)
    end

    # The property the month headline leans on: the total is what the two
    # published subsets are subsets *of*. Without it the page could only show
    # matched beside open — ₹1,000 and ₹10,000 — with c's ₹4,000 sitting in
    # neither and no way for a reader adding them to notice the shortfall.
    test "total_tax_paise closes: matched + accepted + open, with nothing falling between" do
      rows = [
        row("a", "matched", nil, 1_000),
        row("b", "needs_human", nil, 2_000),
        row("c", "in_books_not_2b", "await_2b", 4_000),
        row("d", "in_2b_not_books", nil, 8_000)
      ]

      summary = Register.summary(rows)
      accepted = 4_000

      assert summary["total_tax_paise"] == 15_000

      assert summary["total_tax_paise"] ==
               summary["matched_tax_paise"] + accepted + summary["open_tax_paise"]
    end

    defp row(id, bucket, accepted_reason, tax) do
      %{
        "id" => id,
        "bucket" => bucket,
        "accepted_reason" => accepted_reason,
        "taxable_paise" => tax * 10,
        "cgst_paise" => div(tax, 2),
        "sgst_paise" => div(tax, 2),
        "igst_paise" => 0,
        "flags" => []
      }
    end
  end

  # The label is stored on the row, so a snapshot or a deliverable that renders
  # it verbatim repeats whatever claim it makes. A matched bill with an invalid
  # GSTIN is not a clean match, and must not say it is anywhere.
  describe "rows/3 bucket_label" do
    test "only flags the 2B cannot answer cost a matched row its clean label" do
      invoices =
        for id <- ~w(clean eligibility transcription), do: %{"id" => id, "taxable_paise" => 1_000}

      recon = %{
        "matched" =>
          for id <- ~w(clean eligibility transcription) do
            %{"books" => %{"id" => id}, "match_basis" => ["gstin", "invoice_number", "value"]}
          end
      }

      flags = %{
        "eligibility" => [%{"code" => "invalid_gstin", "reason" => "bad gstin"}],
        "transcription" => [%{"code" => "low_ocr_confidence", "reason" => "faint scan"}]
      }

      by_id = invoices |> Register.rows(recon, flags) |> Map.new(&{&1["id"], &1})

      assert by_id["clean"]["bucket_label"] == "Matched to 2B"
      assert by_id["eligibility"]["bucket_label"] == "Matched · needs review"
      assert Register.needs_review?(by_id["eligibility"])

      # The portal confirmed this bill field-for-field, which is stronger than a
      # confidence score's doubt. Quiet pill, but the note still speaks.
      assert by_id["transcription"]["bucket_label"] == "Matched to 2B"
      refute Register.needs_review?(by_id["transcription"])
      assert Register.annotated_row?(by_id["transcription"])
      refute Register.annotated_row?(by_id["clean"])

      # Wording only: every row is still matched, so ITC and the queue are untouched.
      for id <- ~w(clean eligibility transcription) do
        assert by_id[id]["bucket"] == "matched"
        refute Register.open_row?(by_id[id])
      end
    end

    # An unmatched row was never corroborated, so nothing is settled and the
    # bucket keeps speaking for it.
    test "needs_review? is a verdict about matched rows only" do
      unmatched = %{
        "bucket" => "needs_human",
        "flags" => [%{"code" => "invalid_gstin"}],
        "accepted_reason" => nil
      }

      refute Register.needs_review?(unmatched)
      assert Register.open_row?(unmatched)
      assert Register.annotated_row?(unmatched)
    end
  end
end
