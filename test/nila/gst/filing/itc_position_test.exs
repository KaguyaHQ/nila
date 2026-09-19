defmodule Nila.Gst.Filing.ItcPositionTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.ItcPosition

  test "not claiming removes selected tax once, retaining other portal invoices" do
    excluded = Map.merge(g2b(2_000), %{"invoice_number" => "excluded"})
    other = Map.merge(g2b(6_000), %{"invoice_number" => "other"})

    recon = %{
      empty_recon()
      | "in_2b_not_books" => [%{"gstr2b" => excluded}, %{"gstr2b" => other}]
    }

    case_line = no_claim_case(excluded)

    position =
      recon
      |> ItcPosition.compute([], %{}, [case_line])
      |> ItcPosition.apply_document_cases([case_line])

    assert position["reported_2b_paise"] == 8_000
    assert position["claimable_paise"] == 6_000
    assert position["not_claiming_paise"] == 2_000
    assert position["awaiting_document_paise"] == 6_000
    assert position["unsubstantiated_withheld_paise"] == 0

    return =
      Nila.Gst.Filing.Gstr3b.assemble(%{"igst" => 0, "cgst" => 0, "sgst" => 0}, recon, position)

    assert return["itc"]["net_itc_4c"] == %{"igst" => 0, "cgst" => 3_000, "sgst" => 3_000}
  end

  test "not claiming supersedes the same invoice's pending and blocked amounts" do
    excluded =
      Map.merge(g2b(2_000), %{"invoice_number" => "excluded", "vendor_gstin" => "supplier"})

    other = Map.merge(g2b(6_000), %{"invoice_number" => "other"})
    case_line = no_claim_case(excluded)

    flagged =
      row("excluded", %{
        "vendor_gstin" => "supplier",
        "cgst_paise" => 1_000,
        "sgst_paise" => 1_000,
        "flags" => [flag("personal_expense_17_5")]
      })

    decisions = %{ItcPosition.block_id("excluded", "personal_expense_17_5") => "block_itc"}

    for bucket <- ~w(matched needs_human) do
      recon =
        empty_recon()
        |> Map.put(bucket, [%{"gstr2b" => excluded}])
        |> Map.put("in_2b_not_books", [%{"gstr2b" => other}])

      position = ItcPosition.compute(recon, [flagged], decisions, [case_line])
      assert position["claimable_paise"] == 6_000
      assert position["not_claiming_paise"] == 2_000
      assert position["pending_decision_paise"] == 0
      assert position["blocked_in_ceiling_paise"] == 0
    end
  end

  test "not claiming removes a paired books block when invoice numbers differ" do
    excluded = keyed(g2b(2_000), "CHN-SER-1134")
    other = keyed(g2b(6_000), "other")

    for bucket <- ~w(matched value_mismatch) do
      flagged =
        row("books-id", %{
          "invoice_number" => "1134",
          "bucket" => bucket,
          "cgst_paise" => 1_000,
          "sgst_paise" => 1_000,
          "flags" => [flag("personal_expense_17_5")]
        })

      recon =
        empty_recon()
        |> Map.put(bucket, [%{"books" => flagged, "gstr2b" => excluded}])
        |> Map.put("in_2b_not_books", [%{"gstr2b" => other}])

      decisions = %{ItcPosition.block_id("books-id", "personal_expense_17_5") => "block_itc"}
      assert ItcPosition.compute(recon, [flagged], decisions)["blocked_in_ceiling_paise"] == 2_000

      position = ItcPosition.compute(recon, [flagged], decisions, [no_claim_case(excluded)])

      assert position["reported_2b_paise"] == 8_000
      assert position["not_claiming_paise"] == 2_000
      assert position["claimable_paise"] == 6_000
      assert position["blocked_in_ceiling_paise"] == 0
      assert position["blocks"] == []
    end
  end

  defp empty_recon, do: Map.put(base_recon(), "matched", [])

  test "a no-claim candidate keeps the other ambiguous invoices pending in either order" do
    excluded = Map.merge(g2b(2_000), %{"invoice_number" => "excluded"})
    other = Map.merge(g2b(6_000), %{"invoice_number" => "other"})

    for candidates <- [[excluded, other], [other, excluded]] do
      recon = Map.put(empty_recon(), "needs_human", [%{"candidates" => candidates}])
      position = ItcPosition.compute(recon, [], %{}, [no_claim_case(excluded)])
      assert position["reported_2b_paise"] == 8_000
      assert position["not_claiming_paise"] == 2_000
      assert position["pending_decision_paise"] == 6_000
      assert position["claimable_paise"] == 0
    end
  end

  defp no_claim_case(invoice) do
    %{
      claim_state: "not_claiming",
      current_gstr2b?: true,
      has_books?: false,
      document_type: "invoice",
      document_state: "not_held",
      tax_heads: invoice["tax_paise"],
      source_refs: %{
        "gstr2b" => %{"2026-08" => Nila.Gst.Purchase.Reconciliation.gstr2b_ref(invoice)}
      }
    }
  end

  # A 2B row carrying `tax` total (split cgst/sgst for intrastate).
  defp g2b(tax),
    do: %{"tax_paise" => %{"cgst" => div(tax, 2), "sgst" => div(tax, 2), "igst" => 0}}

  defp row(id, attrs) do
    Map.merge(
      %{
        "id" => id,
        "vendor_name" => "V",
        "vendor_gstin" => "33AAACS1234A1Z9",
        "invoice_number" => id,
        "cgst_paise" => 0,
        "sgst_paise" => 0,
        "igst_paise" => 0,
        "flags" => []
      },
      attrs
    )
  end

  defp flag(code, section \\ nil),
    do: %{"code" => code, "severity" => "review", "section" => section, "reason" => "r"}

  test "ceiling sums all 2B tax across matched, value_mismatch, 2B-only, and awaiting" do
    recon = %{
      "matched" => [%{"gstr2b" => g2b(10_000)}],
      "value_mismatch" => [%{"gstr2b" => g2b(2_000)}],
      "in_2b_not_books" => [%{"gstr2b" => g2b(3_000)}],
      "needs_human" => [%{"candidates" => [g2b(5_000)]}],
      "in_books_not_2b" => []
    }

    pos = ItcPosition.compute(recon, [], %{})
    assert pos["ceiling_paise"] == 20_000
    assert pos["blocks"] == []

    # The ceiling is what the portal reported; the claim is what is left after
    # the states that own their rupees. The ₹50 routed to a human is pending,
    # and the ₹30 with no bill on file is claimed but unsubstantiated.
    assert pos["reported_2b_paise"] == 20_000
    assert pos["pending_decision_paise"] == 5_000
    assert pos["claimable_paise"] == 15_000
    assert pos["awaiting_document_paise"] == 3_000
    assert pos["substantiated_paise"] == 12_000
  end

  test "debit notes increase 4A while positive-valued credit notes reduce the claim" do
    invoice = Map.put(g2b(18_000), "document_type", "invoice")
    debit = Map.put(g2b(1_800), "document_type", "debit_note")
    credit = Map.put(g2b(3_600), "document_type", "credit_note")

    recon = %{
      "matched" => [%{"gstr2b" => keyed(invoice, "INV-1")}],
      "value_mismatch" => [],
      "in_2b_not_books" => [
        %{"gstr2b" => keyed(debit, "DN-1")},
        %{"gstr2b" => keyed(credit, "CN-1")}
      ],
      "needs_human" => [],
      "in_books_not_2b" => []
    }

    position = ItcPosition.compute(recon, [], %{})

    assert position["ceiling_paise"] == 19_800
    assert position["credit_note_reversal_paise"] == 3_600
    assert position["credit_note_reversal_applied_paise"] == 3_600
    assert position["claimable_paise"] == 16_200
    assert position["awaiting_document_paise"] == 1_800

    assert position["reported_2b_paise"] ==
             position["claimable_paise"] + position["pending_decision_paise"] +
               position["blocked_in_ceiling_paise"] +
               position["credit_note_reversal_applied_paise"]
  end

  test "a books-only supplier credit note still reverses ITC conservatively" do
    invoice = keyed(Map.put(g2b(18_000), "document_type", "invoice"), "INV-1")

    books_credit = %{
      "document_type" => "credit_note",
      "vendor_gstin" => "33AAACS1234A1Z9",
      "invoice_number" => "CN-1",
      "tax_paise" => %{"cgst" => 1_800, "sgst" => 1_800, "igst" => 0}
    }

    recon = %{
      "matched" => [%{"gstr2b" => invoice}],
      "value_mismatch" => [],
      "in_2b_not_books" => [],
      "needs_human" => [],
      "in_books_not_2b" => [%{"books" => books_credit}]
    }

    position = ItcPosition.compute(recon, [], %{})

    assert position["ceiling_paise"] == 18_000
    assert position["credit_note_reversal_paise"] == 3_600
    assert position["claimable_paise"] == 14_400
  end

  test "awaiting 2B tax is deduped (ambiguous pair lists same candidate twice)" do
    g = g2b(5_000)

    recon = %{
      "matched" => [],
      "value_mismatch" => [],
      "in_2b_not_books" => [],
      "needs_human" => [
        %{"candidates" => [Map.merge(g, %{"vendor_gstin" => "X", "invoice_number" => "1"})]},
        %{"candidates" => [Map.merge(g, %{"vendor_gstin" => "X", "invoice_number" => "1"})]}
      ],
      "in_books_not_2b" => []
    }

    assert ItcPosition.compute(recon, [], %{})["ceiling_paise"] == 5_000
  end

  describe "the partition" do
    # A bridge is arithmetic. If these two equations do not close, every figure
    # on the ITC panel is a number that looks precise and isn't.
    test "reported 2B splits into terminal states, and the claim splits by substantiation" do
      recon = %{
        "matched" => [%{"gstr2b" => keyed(g2b(40_000), "M-1")}],
        "value_mismatch" => [%{"gstr2b" => keyed(g2b(6_000), "V-1")}],
        "in_2b_not_books" => [%{"gstr2b" => keyed(g2b(9_000), "O-1")}],
        "needs_human" => [%{"candidates" => [keyed(g2b(5_000), "H-1")]}],
        "in_books_not_2b" => []
      }

      rows = [
        row("m1", %{
          "bucket" => "matched",
          "invoice_number" => "M-1",
          "cgst_paise" => 1_000,
          "sgst_paise" => 1_000,
          "flags" => [flag("personal_expense_17_5", "17(5)")]
        })
      ]

      [%{"block_id" => bid}] = ItcPosition.compute(recon, rows, %{})["blocks"]
      pos = ItcPosition.compute(recon, rows, %{bid => "block_itc"})

      assert pos["reported_2b_paise"] ==
               pos["claimable_paise"] + pos["pending_decision_paise"] +
                 pos["blocked_in_ceiling_paise"]

      assert pos["claimable_paise"] ==
               pos["substantiated_paise"] + pos["awaiting_document_paise"]

      assert pos["reported_2b_paise"] == 60_000
      assert pos["blocked_in_ceiling_paise"] == 2_000
      assert pos["pending_decision_paise"] == 5_000
      assert pos["claimable_paise"] == 53_000
      assert pos["awaiting_document_paise"] == 9_000
      assert pos["substantiated_paise"] == 44_000
    end

    test "blocking a bill the portal never reported cannot take the claim negative" do
      # There is no 2B credit behind a books-only bill, so there is nothing to
      # withhold. Subtracting it produced a claimable ITC of −₹180.
      recon = %{
        "matched" => [],
        "value_mismatch" => [],
        "in_2b_not_books" => [],
        "needs_human" => [],
        "in_books_not_2b" => []
      }

      rows = [
        row("ghost", %{
          "bucket" => "in_books_not_2b",
          "cgst_paise" => 9_000,
          "sgst_paise" => 9_000,
          "flags" => [flag("personal_expense_17_5", "17(5)")]
        })
      ]

      [%{"block_id" => bid}] = ItcPosition.compute(recon, rows, %{})["blocks"]
      pos = ItcPosition.compute(recon, rows, %{bid => "block_itc"})

      assert pos["claimable_paise"] == 0
      assert pos["blocked_in_ceiling_paise"] == 0

      # The decision is still recorded and still reported — it just does not
      # move a ceiling it was never part of.
      assert pos["blocked_paise"] == 18_000
      assert pos["blocked_outside_ceiling_paise"] == 18_000
      assert [%{"state" => "blocked"}] = pos["blocks"]
    end

    test "an accepted 2B-only row is no longer awaiting a document" do
      recon = %{
        "matched" => [],
        "value_mismatch" => [],
        "in_2b_not_books" => [
          %{"gstr2b" => keyed(g2b(4_000), "A-1")},
          %{"gstr2b" => keyed(g2b(6_000), "A-2")}
        ],
        "needs_human" => [],
        "in_books_not_2b" => []
      }

      rows = [
        row("x", %{
          "bucket" => "in_2b_not_books",
          "invoice_number" => "A-1",
          "accepted_reason" => "chased"
        })
      ]

      pos = ItcPosition.compute(recon, rows, %{})

      assert pos["awaiting_document_paise"] == 6_000
      assert pos["substantiated_paise"] == 4_000
      assert pos["claimable_paise"] == 10_000
    end

    test "both equations hold across every combination of buckets and decisions" do
      # Sampling four hand-built shapes proves those four shapes. The claim is
      # that the partition closes, so it is exercised over the cross product of
      # the states a month can actually be in.
      for matched <- [0, 40_000],
          mismatch <- [0, 6_000],
          only <- [0, 9_000],
          human <- [0, 5_000],
          block_bucket <- ["matched", "in_books_not_2b", nil],
          decision <- ["block_itc", "allow_itc", nil],
          accepted <- [true, false] do
        recon = %{
          "matched" => entries(matched, "M"),
          "value_mismatch" => entries(mismatch, "V"),
          "in_2b_not_books" => entries(only, "O"),
          "needs_human" =>
            if(human == 0, do: [], else: [%{"candidates" => [keyed(g2b(human), "H")]}]),
          "in_books_not_2b" => []
        }

        block_rows =
          if block_bucket do
            [
              row("b", %{
                "bucket" => block_bucket,
                "invoice_number" => "M",
                "cgst_paise" => 1_000,
                "sgst_paise" => 1_000,
                "flags" => [flag("personal_expense_17_5", "17(5)")]
              })
            ]
          else
            []
          end

        accepted_rows =
          if accepted and only > 0 do
            [
              row("acc", %{
                "bucket" => "in_2b_not_books",
                "invoice_number" => "O",
                "accepted_reason" => "chased"
              })
            ]
          else
            []
          end

        rows = block_rows ++ accepted_rows

        decisions =
          case {decision, ItcPosition.compute(recon, rows, %{})["blocks"]} do
            {nil, _blocks} -> %{}
            {_verb, []} -> %{}
            {verb, [%{"block_id" => bid} | _rest]} -> %{bid => verb}
          end

        pos = ItcPosition.compute(recon, rows, decisions)
        shape = inspect({matched, mismatch, only, human, block_bucket, decision, accepted})

        assert pos["reported_2b_paise"] ==
                 pos["claimable_paise"] + pos["pending_decision_paise"] +
                   pos["blocked_in_ceiling_paise"],
               "terminal states do not sum for #{shape}"

        assert pos["claimable_paise"] ==
                 pos["substantiated_paise"] + pos["awaiting_document_paise"],
               "claim does not split for #{shape}"

        assert pos["claimable_paise"] >= 0, "negative claim for #{shape}"
        assert pos["substantiated_paise"] >= 0, "negative substantiated for #{shape}"
      end
    end

    test "a clamped term is reported, not quietly absorbed" do
      # `rows` and `recon` are two projections of one month and can disagree.
      # The clamp keeps the equation an identity, but a clamp that fires
      # silently turns a data inconsistency into a clean split nobody can
      # question.
      handler = {__MODULE__, :clamp, self()}

      :telemetry.attach(
        handler,
        ItcPosition.clamp_event(),
        fn _event, measurements, metadata, pid ->
          send(pid, {:clamped, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # A row claiming a matched bucket with no 2B entry behind it.
      recon = %{
        "matched" => [],
        "value_mismatch" => [],
        "in_2b_not_books" => [],
        "needs_human" => [],
        "in_books_not_2b" => []
      }

      rows = [
        row("phantom", %{
          "bucket" => "matched",
          "cgst_paise" => 1_000,
          "sgst_paise" => 1_000,
          "flags" => [flag("personal_expense_17_5", "17(5)")]
        })
      ]

      [%{"block_id" => bid}] = ItcPosition.compute(recon, rows, %{})["blocks"]
      pos = ItcPosition.compute(recon, rows, %{bid => "block_itc"})

      assert pos["claimable_paise"] == 0
      assert_receive {:clamped, %{raw_paise: 2_000, clamped_paise: 0}, %{term: :blocked}}
    end

    test "a value mismatch is claimable, not pending — no answer moves the money" do
      recon = %{
        "matched" => [],
        "value_mismatch" => [%{"gstr2b" => keyed(g2b(7_000), "V-9")}],
        "in_2b_not_books" => [],
        "needs_human" => [],
        "in_books_not_2b" => []
      }

      pos = ItcPosition.compute(recon, [], %{})

      assert pos["pending_decision_paise"] == 0
      assert pos["claimable_paise"] == 7_000
      assert pos["substantiated_paise"] == 7_000
    end
  end

  defp keyed(g2b, inum),
    do: Map.merge(g2b, %{"vendor_gstin" => "33AAACS1234A1Z9", "invoice_number" => inum})

  defp entries(0, _inum), do: []
  defp entries(tax, inum), do: [%{"gstr2b" => keyed(g2b(tax), inum)}]

  defp base_recon,
    do: %{
      "matched" => [%{"gstr2b" => g2b(100_000)}],
      "value_mismatch" => [],
      "in_2b_not_books" => [],
      "needs_human" => [],
      "in_books_not_2b" => []
    }

  test "personal-expense and state-mismatch stake the full row tax, one block each" do
    rows = [
      row("a", %{
        "cgst_paise" => 945,
        "sgst_paise" => 945,
        "flags" => [flag("personal_expense_17_5", "CGST Act 17(5)(g)")]
      }),
      row("b", %{"igst_paise" => 194, "flags" => [flag("gstin_state_mismatch", "IGST Act s.10")]})
    ]

    pos = ItcPosition.compute(base_recon(), rows, %{})
    codes = Enum.map(pos["blocks"], & &1["code"])
    assert codes == ["personal_expense_17_5", "gstin_state_mismatch"]
    assert pos["recommended_paise"] == 1890 + 194
    # nothing confirmed yet: claimable still the full ceiling
    assert pos["claimable_paise"] == 100_000
  end

  test "a duplicate group is ONE block staking the excess (N-1 copies), not per copy" do
    dup = flag("duplicate_invoice")

    rows = [
      row("d1", %{
        "invoice_number" => "254111",
        "cgst_paise" => 157,
        "sgst_paise" => 158,
        "flags" => [dup]
      }),
      row("d2", %{
        "invoice_number" => "254111",
        "cgst_paise" => 157,
        "sgst_paise" => 158,
        "flags" => [dup]
      })
    ]

    pos = ItcPosition.compute(base_recon(), rows, %{})
    assert [block] = pos["blocks"]
    assert block["code"] == "duplicate_invoice"
    assert block["document_type"] == "invoice"
    # 2 copies of 315 -> block one copy's 315, keep the other
    assert block["tax_paise"] == 315
  end

  test "three identical copies block two copies' worth" do
    dup = flag("duplicate_invoice")

    rows =
      for id <- ["a", "b", "c"],
          do:
            row(id, %{
              "invoice_number" => "X",
              "cgst_paise" => 500,
              "sgst_paise" => 500,
              "flags" => [dup]
            })

    pos = ItcPosition.compute(base_recon(), rows, %{})
    assert [block] = pos["blocks"]
    assert block["tax_paise"] == 2_000
  end

  test "confirming a block reduces claimable; overriding to allow keeps the credit" do
    rows = [
      row("a", %{
        "cgst_paise" => 500,
        "sgst_paise" => 500,
        "flags" => [flag("personal_expense_17_5")]
      })
    ]

    [%{"block_id" => bid}] = ItcPosition.compute(base_recon(), rows, %{})["blocks"]

    blocked = ItcPosition.compute(base_recon(), rows, %{bid => "block_itc"})
    assert blocked["blocked_paise"] == 1_000
    assert blocked["claimable_paise"] == 99_000
    assert [%{"state" => "blocked"}] = blocked["blocks"]

    allowed = ItcPosition.compute(base_recon(), rows, %{bid => "allow_itc"})
    assert allowed["blocked_paise"] == 0
    assert allowed["claimable_paise"] == 100_000
    assert [%{"state" => "allowed"}] = allowed["blocks"]
    # allowed items drop out of the "recommended" total
    assert allowed["recommended_paise"] == 0
  end
end
