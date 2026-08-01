defmodule NilaWeb.Components.Gst.Month.VerdictTest do
  use ExUnit.Case, async: true

  alias NilaWeb.Components.Gst.Month.Verdict

  @moduledoc """
  The state table, as data.

  The plan's rule is the spec and its table is worked examples, so this file
  tests the rule: derive each track independently, give the door to the
  highest-precedence track with live work for the viewer's role, make every
  other pending track a quiet line, and never render a second button.
  """

  @today ~D[2026-05-14]
  @period "2026-04"

  defp facts(overrides) do
    %{
      tracks: %{sales: :absent, purchase: :absent},
      stats: nil,
      gstr3b: nil,
      purchase_month: nil,
      sales_month: nil,
      open_issue_count: 0,
      r1_signoff: nil,
      gstr3b_signoff: nil,
      can_sign_off: true,
      attention_dumps: [],
      open_period: "2026-04",
      client: %{id: Ecto.UUID.generate(), name: "Caltech"},
      period: @period,
      today: @today
    }
    |> Map.merge(Map.new(overrides))
  end

  # `total_tax` defaults to matched + open, which is what a register with no
  # audited-accepted rows actually sums to. Tests that care about the gap pass
  # it explicitly.
  defp stats(need_decision, open_tax, matched_tax, total_tax \\ nil) do
    %{
      invoices: 23,
      matched: 23 - need_decision,
      need_decision: need_decision,
      taxable_paise: 0,
      total_tax_paise: total_tax || matched_tax + open_tax,
      matched_tax_paise: matched_tax,
      open_tax_paise: open_tax
    }
  end

  defp door_id(verdict), do: verdict.door && verdict.door.id

  describe "the state table" do
    test "nothing in yet" do
      verdict = Verdict.resolve(facts([]))

      assert verdict.headline == "Nothing in yet for Apr 2026."
      assert door_id(verdict) == "month-door-bring-documents"
    end

    test "extracting: live progress, and deliberately no door to press" do
      verdict =
        Verdict.resolve(
          facts(attention_dumps: [%{id: 1, status: "extracting", kind: "purchase"}])
        )

      assert verdict.headline =~ "Reading the bills"
      assert verdict.door == nil
    end

    test "a failed pile outranks the work underneath it" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :absent, purchase: :open},
            stats: stats(12, 1_390_000, 5_840_000),
            attention_dumps: [%{id: 1, status: "failed", kind: "purchase"}]
          )
        )

      assert verdict.tone == :alarm
      assert verdict.headline =~ "failed to extract"
      assert door_id(verdict) == "month-door-failed-pile"
    end

    test "a held pile offers release only to someone who can lift the signature" do
      dump = %{id: 7, status: "held", kind: "purchase"}

      verdict = Verdict.resolve(facts(attention_dumps: [dump]))
      assert door_id(verdict) == "month-door-release-pile"
      assert verdict.door.value == %{"dump-id" => 7}

      # Signed off, so the pile cannot be released until the signature is
      # reopened. It is not an actionable interrupt, so the page falls through
      # to the state underneath and the pile waits in the paper trail.
      signed =
        Verdict.resolve(
          facts(
            attention_dumps: [dump],
            tracks: %{sales: :filed, purchase: :signed},
            gstr3b_signoff: %{signed_by: %{name: "Vasanth"}}
          )
        )

      assert door_id(signed) == "month-door-file-purchase"
    end

    # The lead is the *whole* month's ITC (₹75,000 here, not the ₹72,300 that
    # matched + open comes to — ₹2,700 sits in audited-accepted rows), and the
    # open figure is stated as a subset of it. The copy this replaced put
    # matched beside open and called matched "clean": two numbers that sum to
    # nothing, one of them claiming a finality the month has not reached.
    test "purchases open, sales absent (the screenshot): money first, one door" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :absent, purchase: :open},
            stats: stats(12, 1_390_000, 5_840_000, 7_500_000)
          )
        )

      assert verdict.headline == "₹75,000 of ITC this month. ₹13,900 of it rides on 12 decisions."
      assert door_id(verdict) == "month-door-decisions"
      assert verdict.quiet == ["Sales bills not in, so the GSTR-1 waits."]
      assert verdict.deadline.return == "GSTR-3B"
    end

    # The state every client sits in for the first two weeks of a filing
    # month. `reconcile(books, [])` happily buckets the whole register as
    # unmatched, and the page used to read that as a pile of judgements and
    # point a primary button at it. There is nothing to judge against yet.
    test "bills in, portal has not published the 2B: a date, and deliberately no door" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :filed, purchase: :awaiting_2b},
            stats: stats(14, 7_956_600, 0),
            today: ~D[2026-05-03]
          )
        )

      assert verdict.headline =~ "23 purchase bills in, carrying ₹79,566 of ITC."
      assert verdict.headline =~ "publishes the GSTR-2B on 14 May 2026"
      refute verdict.headline =~ "decision"
      assert is_nil(verdict.door)
    end

    # Waiting on the portal is nobody's move; waiting on the client is a chase
    # somebody can start now. The clock keeps the 2B date as a quiet line.
    test "no 2B yet and no sales bills: the chase wins, the 2B date stays visible" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :absent, purchase: :awaiting_2b},
            stats: stats(14, 7_956_600, 0),
            today: ~D[2026-05-03]
          )
        )

      assert door_id(verdict) == "month-door-bring-sales"
      assert "Purchases: the GSTR-2B lands 14 May 2026." in verdict.quiet
    end

    test "the 2B is out and nobody fetched it: that outranks the decisions behind it" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :filed, purchase: :need_2b},
            stats: stats(14, 7_956_600, 0)
          )
        )

      assert verdict.headline =~ "has been out since 14 May 2026"
      assert verdict.headline =~ "Nothing reconciles until it is in."
      assert door_id(verdict) == "month-door-bring-2b"
    end

    # An absent track is somebody else's move; a missing 2B is *this* reader's.
    test "no 2B and no sales bills: fetching the 2B wins over chasing the client" do
      verdict =
        Verdict.resolve(
          facts(tracks: %{sales: :absent, purchase: :need_2b}, stats: stats(14, 7_956_600, 0))
        )

      assert door_id(verdict) == "month-door-bring-2b"
      assert "Sales bills not in, so the GSTR-1 waits." in verdict.quiet
    end

    # Falls out of the ordering rather than being asserted anywhere: :clear is
    # unreachable while the 2B is missing, so a 3B can never be signed against
    # a reconciliation that never happened.
    test "a 3B cannot be signed while the 2B is missing" do
      for purchase <- [:awaiting_2b, :need_2b] do
        verdict =
          Verdict.resolve(
            facts(
              tracks: %{sales: :filed, purchase: purchase},
              stats: stats(14, 7_956_600, 0),
              can_sign_off: true
            )
          )

        refute door_id(verdict) == "month-door-sign-3b"
      end
    end

    test "purchases open, sales open: purchases win, sales becomes a line" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :open, purchase: :open},
            stats: stats(12, 1_390_000, 5_840_000),
            open_issue_count: 3
          )
        )

      assert door_id(verdict) == "month-door-decisions"
      assert verdict.quiet == ["GSTR-1 drafted, issues still to check."]
    end

    test "sales filed, purchases open: the 11th-to-20th window every client sits in" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :filed, purchase: :open},
            stats: stats(12, 1_390_000, 5_840_000)
          )
        )

      # The headline no longer spends its opening clause on "GSTR-1 filed" —
      # the quiet line below already carries that, and the headline's job is
      # the money the door is about.
      assert verdict.headline == "₹72,300 of ITC this month. ₹13,900 of it rides on 12 decisions."
      assert door_id(verdict) == "month-door-decisions"
      assert verdict.quiet == ["GSTR-1 filed."]
      assert verdict.deadline.return == "GSTR-3B"
    end

    test "purchases clear, sales issues open" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :open, purchase: :clear},
            stats: stats(0, 0, 5_840_000),
            open_issue_count: 3
          )
        )

      assert verdict.headline == "Purchases clear, ₹58,400 ITC. GSTR-1 has 3 issues to check."
      assert is_nil(verdict.door)
      assert verdict.deadline.return == "GSTR-1"
    end

    test "sales issues stay in the visible register instead of creating a dispatcher door" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :open, purchase: :clear},
            stats: stats(0, 0, 5_840_000),
            open_issue_count: 2
          )
        )

      assert verdict.headline =~ "2 issues to check"
      assert is_nil(verdict.door)
    end

    test "sales drafted and clean: the header yields the approval gesture to the register" do
      verdict =
        Verdict.resolve(facts(tracks: %{sales: :open, purchase: :clear}, can_sign_off: false))

      assert verdict.headline =~ "approve it below"
      assert is_nil(verdict.door)
    end

    test "both worked and unsigned: the senior signs in filing order" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :clear, purchase: :clear},
            gstr3b: %{
              "itc" => %{"net_itc_4c" => %{"cgst" => 2_920_000, "sgst" => 2_920_000, "igst" => 0}},
              "setoff_61" => %{"cash_total" => 12_300_000}
            }
          )
        )

      assert verdict.headline == "Clean. ₹58,400 ITC, ₹1,23,000 payable."
      assert is_nil(verdict.door)
    end

    # At the 3B signature the payable is the fact the senior is putting their
    # name to, so it leads rather than trailing the word "Clean". The GSTR-1
    # signature above has no payable and keeps the rollup.
    test "signing the 3B: the payable leads, not the reconciliation rollup" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :filed, purchase: :clear},
            gstr3b: %{"setoff_61" => %{"cash_total" => 12_300_000}}
          )
        )

      assert verdict.headline == "₹1,23,000 payable. Worked and clean."
      assert is_nil(verdict.door)
    end

    test "the GSTR-3B signs only once the GSTR-1 is out of the way" do
      for sales <- [:signed, :filed] do
        verdict = Verdict.resolve(facts(tracks: %{sales: sales, purchase: :clear}))

        expected = if sales == :signed, do: "month-door-file-sales", else: nil
        assert door_id(verdict) == expected
      end
    end

    test "same state, junior role: nothing to press" do
      verdict =
        Verdict.resolve(facts(tracks: %{sales: :clear, purchase: :clear}, can_sign_off: false))

      assert verdict.headline =~ "Waiting on a senior to sign."
      assert verdict.door == nil
    end

    test "signed, not filed: the filing gap outranks everything else open" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :open, purchase: :signed},
            stats: stats(12, 1_390_000, 5_840_000),
            open_issue_count: 3,
            gstr3b_signoff: %{signed_by: %{name: "Vasanth"}}
          )
        )

      assert verdict.headline == "GSTR-3B signed by Vasanth. It is not on the portal yet."
      assert door_id(verdict) == "month-door-file-purchase"
      assert verdict.door.to == "#month-exit-gstr3b"
    end

    # Cash payable is the only number in the month that leaves the client's
    # bank account, and this is the one state where it is settled and unpaid.
    # It leads; the signature line follows it.
    test "signed, not filed, and money is due: the payable leads" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :filed, purchase: :signed},
            gstr3b_signoff: %{signed_by: %{name: "Vasanth"}},
            gstr3b: %{"setoff_61" => %{"cash_total" => 12_300_000}}
          )
        )

      assert verdict.headline ==
               "₹1,23,000 payable. GSTR-3B signed by Vasanth. It is not on the portal yet."
    end

    # A nil setoff means the number was never established, and a zero one is
    # not news worth the lead — the whole point of this pass was to stop the
    # hero announcing ₹0 as a finding.
    test "an unestablished or zero payable does not earn the lead" do
      for setoff <- [nil, %{"setoff_61" => %{"cash_total" => 0}}, %{"setoff_61" => %{}}] do
        verdict =
          Verdict.resolve(
            facts(
              tracks: %{sales: :filed, purchase: :signed},
              gstr3b_signoff: %{signed_by: %{name: "Vasanth"}},
              gstr3b: setoff
            )
          )

        assert verdict.headline == "GSTR-3B signed by Vasanth. It is not on the portal yet."
      end
    end

    # The GSTR-1 is a disclosure, not a payment, so its file door keeps the
    # plain line even when the 3B beside it has a payable.
    test "the GSTR-1's file door never borrows the 3B's payable" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :signed, purchase: :open},
            r1_signoff: %{signed_by: %{name: "Vasanth"}},
            gstr3b: %{"setoff_61" => %{"cash_total" => 12_300_000}}
          )
        )

      assert verdict.headline == "GSTR-1 signed by Vasanth. It is not on the portal yet."
    end

    test "filed: the page runs out of content when the work runs out" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :filed, purchase: :filed},
            purchase_month: %{filed_at: ~U[2026-05-12 09:00:00Z], filing_arn: "AB33"}
          )
        )

      assert verdict.headline == "Filed · 12 May 2026 · ARN AB33. Month closed."
      assert verdict.door == nil
      assert verdict.deadline == nil
    end

    test "documents after filing route to the month that can still take them" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :filed, purchase: :filed},
            attention_dumps: [%{id: 3, status: "after_filing", kind: "purchase"}],
            open_period: "2026-06"
          )
        )

      assert verdict.headline =~ "arrived after this month was filed"
      assert door_id(verdict) == "month-door-after-filing"
      assert verdict.door.to =~ "period=2026-06"
    end
  end

  describe "the rules the table is an example of" do
    test "no state offers two doors" do
      for sales <- [:absent, :open, :clear, :signed, :filed],
          purchase <- [:absent, :awaiting_2b, :need_2b, :open, :clear, :signed, :filed],
          can_sign_off <- [true, false] do
        verdict =
          Verdict.resolve(
            facts(
              tracks: %{sales: sales, purchase: purchase},
              stats: stats(2, 1000, 2000),
              open_issue_count: 1,
              can_sign_off: can_sign_off
            )
          )

        assert is_nil(verdict.door) or is_map(verdict.door),
               "#{sales}/#{purchase} produced #{inspect(verdict.door)}"

        assert is_binary(verdict.headline) and verdict.headline != ""
      end
    end

    test "the door's track is never also a quiet line" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :open, purchase: :open},
            stats: stats(2, 1000, 2000),
            open_issue_count: 1
          )
        )

      refute Enum.any?(verdict.quiet, &String.contains?(&1, "Purchases:"))
    end

    test "an old unfiled month keeps its alarm; late is late" do
      verdict =
        Verdict.resolve(
          facts(
            tracks: %{sales: :absent, purchase: :open},
            stats: stats(12, 1_390_000, 5_840_000),
            today: ~D[2026-11-01]
          )
        )

      assert verdict.deadline.days_left < 0
    end
  end
end
