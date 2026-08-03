defmodule Nila.Gst.Purchase.GroupsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Purchase.{Groups, Reconciliation, Workings}

  @gstin "33AAACS1234A1Z9"

  defp books(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "vendor_name" => "Sharma Steels",
        "vendor_gstin" => @gstin,
        "invoice_number" => "INV-001",
        "invoice_date" => ~D[2025-04-15],
        "taxable_paise" => 1_000_000,
        "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
        "total_paise" => 1_180_000
      },
      attrs
    )
  end

  defp gstr2b(number, attrs \\ %{}) do
    Map.merge(
      %{
        "vendor_gstin" => @gstin,
        "vendor_name" => "SHARMA STEELS",
        "invoice_number" => number,
        "invoice_date" => ~D[2025-04-15],
        "taxable_paise" => 1_000_000,
        "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
        "total_paise" => 1_180_000
      },
      attrs
    )
  end

  defp needs(books, candidates) do
    %{
      "books" => books,
      "candidates" => candidates,
      "reason" => %{"code" => "ambiguous_matches", "message" => "Choose a pairing."}
    }
  end

  defp recon(attrs) do
    Map.merge(
      %{
        "matched" => [],
        "value_mismatch" => [],
        "needs_human" => [],
        "in_books_not_2b" => [],
        "in_2b_not_books" => []
      },
      attrs
    )
  end

  describe "build/1" do
    test "derives settled 1↔1 components" do
      books = books("b1")
      counterpart = gstr2b("G-1")

      assert [group] =
               Groups.build(
                 recon(%{
                   "matched" => [%{"books" => books, "gstr2b" => counterpart}]
                 })
               )

      assert group.state == :settled
      assert group.code == "matched"
      assert group.books == [books]
      assert group.counterparts == [counterpart]
      assert [%{books_ref: "b1", bucket: "matched"}] = group.edges
      assert group.tax_paise == 180_000
    end

    test "derives isolated 1↔0 and 0↔1 components" do
      books = books("b1")
      counterpart = gstr2b("G-1")

      groups =
        Groups.build(
          recon(%{
            "in_books_not_2b" => [
              %{
                "books" => books,
                "reason" => %{"code" => "no_confident_gstr2b_match"}
              }
            ],
            "in_2b_not_books" => [
              %{"gstr2b" => counterpart, "reason" => %{"code" => "missing_in_books"}}
            ]
          })
        )

      assert [awaiting, decision] = Enum.sort_by(groups, & &1.state)
      assert awaiting.state == :awaiting_bill
      assert awaiting.books == []
      assert awaiting.counterparts == [counterpart]
      assert decision.state == :needs_decision
      assert decision.books == [books]
      assert decision.counterparts == []
    end

    test "groups 1↔N, N↔1 and N↔M candidate graphs once" do
      b1 = books("b1")
      b2 = books("b2", %{"invoice_number" => "INV-002"})
      g1 = gstr2b("G-1")
      g2 = gstr2b("G-2")

      for {label, entries, books_count, counterpart_count, edge_count} <- [
            {"1↔N", [needs(b1, [g1, g2])], 1, 2, 2},
            {"N↔1", [needs(b1, [g1]), needs(b2, [g1])], 2, 1, 2},
            {"N↔M", [needs(b1, [g1, g2]), needs(b2, [g1, g2])], 2, 2, 4}
          ] do
        assert [group] = Groups.build(recon(%{"needs_human" => entries})), label
        assert group.state == :needs_decision
        assert group.code == "ambiguous_matches"
        assert length(group.books) == books_count
        assert length(group.counterparts) == counterpart_count
        assert length(group.edges) == edge_count
      end
    end

    test "deduplicates repeated edges and anchors the key to sorted durable refs" do
      b1 = books("b1")
      b2 = books("b2")
      g1 = gstr2b("G-1")

      first =
        Groups.build(recon(%{"needs_human" => [needs(b1, [g1, g1]), needs(b2, [g1])]}))
        |> hd()

      second =
        Groups.build(recon(%{"needs_human" => [needs(b2, [g1]), needs(b1, [g1])]}))
        |> hd()

      assert first.key == second.key
      assert length(first.edges) == 2
      assert length(first.counterparts) == 1
    end

    test "FREEZELINKS counts one shared counterpart's tax once" do
      first = books("freezelinks-1")
      second = books("freezelinks-2")
      counterpart = gstr2b("FREEZELINKS")
      effective = Reconciliation.reconcile([first, second], [counterpart])

      assert [group] = Groups.build(effective)
      assert group.state == :needs_decision
      assert length(group.books) == 2
      assert length(group.counterparts) == 1
      assert group.tax_paise == 180_000
    end

    test "reject_pair removes the edge and splits books from its counterpart" do
      books = books("b1")
      counterpart = gstr2b("G-1")
      baseline = Reconciliation.reconcile([books], [counterpart])
      ref = Reconciliation.gstr2b_ref(counterpart)

      effective =
        Workings.materialize(baseline, [
          %{
            "verb" => "reject_pair",
            "books_id" => books["id"],
            "gstr2b_ref" => ref,
            "payload" => %{}
          }
        ])

      groups = Groups.build(effective)
      assert Enum.count(groups, &(&1.state == :needs_decision)) == 1
      assert Enum.count(groups, &(&1.state == :awaiting_bill)) == 1
      assert Enum.all?(groups, &(&1.edges == []))
    end

    test "a confirmation splits a contested component into settled and unresolved groups" do
      first = books("freezelinks-1")
      second = books("freezelinks-2")
      counterpart = gstr2b("FREEZELINKS")
      baseline = Reconciliation.reconcile([first, second], [counterpart])
      ref = Reconciliation.gstr2b_ref(counterpart)

      effective =
        Workings.materialize(baseline, [
          %{
            "verb" => "confirm_pair",
            "books_id" => first["id"],
            "gstr2b_ref" => ref,
            "payload" => %{}
          }
        ])

      groups = Groups.build(effective)
      assert Enum.count(groups, &(&1.state == :settled)) == 1
      assert Enum.count(groups, &(&1.state == :needs_decision)) == 1

      assert groups |> Enum.flat_map(& &1.books) |> Enum.map(& &1["id"]) |> Enum.sort() ==
               ["freezelinks-1", "freezelinks-2"]
    end
  end
end
