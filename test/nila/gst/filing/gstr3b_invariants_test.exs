defmodule Nila.Gst.Filing.Gstr3bInvariantsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.{Gstr3b, ItcPosition}

  @zero %{"igst" => 0, "cgst" => 0, "sgst" => 0, "cess" => 0}
  @liability %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0}
  @recon %{
    "matched" => [],
    "value_mismatch" => [],
    "needs_human" => [],
    "in_2b_not_books" => [],
    "in_books_not_2b" => []
  }

  defp case_line(opening, claim, later, exclude) do
    %{
      document_type: "invoice",
      treatment: "split",
      reverse_charge?: false,
      outstanding_heads: opening,
      treatment_heads: %{"claim" => claim, "later" => later, "exclude" => exclude}
    }
  end

  test "split treatment balances the claim and carry without inventing a reversal" do
    opening = %{@zero | "igst" => 10_000, "cess" => 500}
    claim = %{@zero | "igst" => 3_000, "cess" => 200}
    later = %{@zero | "igst" => 5_000, "cess" => 300}
    exclude = %{@zero | "igst" => 2_000}

    position = ItcPosition.compute(@recon, [], %{}, [case_line(opening, claim, later, exclude)])
    return = Gstr3b.assemble(@liability, @recon, position)

    assert position["opening_outstanding_paise"] ==
             position["current_claim_paise"] + position["later_paise"] +
               position["excluded_paise"]

    assert position["closing_outstanding_heads"] == later
    assert return["itc"]["net_itc_4c"] == claim
    assert return["itc"]["reversed_4b1"] == @zero
    assert return["itc"]["reversed_4b2"] == @zero
    assert return["setoff_61"]["cash_total"] == 0
  end

  test "an undecided case contributes pending credit but no claim" do
    opening = %{@zero | "cgst" => 1_000, "sgst" => 1_000}
    line = %{case_line(opening, @zero, @zero, @zero) | treatment: "undecided"}
    position = ItcPosition.compute(@recon, [], %{}, [line])
    return = Gstr3b.assemble(@liability, @recon, position)

    assert position["pending_heads"] == opening
    assert position["closing_outstanding_heads"] == opening
    assert position["current_claim_paise"] == 0
    assert return["itc"]["net_itc_4c"] == @zero
  end

  test "Table 4 claim stays within the reviewed split even when source or books amounts differ" do
    scenarios = [
      {"three scans, one portal invoice", 100_000, 300_000, 100_000},
      {"books tax exceeds portal tax", 100_000, 500_000, 40_000},
      {"books-only bill beside reported credit", 300_000, 100_000, 200_000},
      {"ordinary reported invoice", 100_000, 100_000, 70_000}
    ]

    for {_name, portal_tax, books_tax, chosen_claim} <- scenarios do
      portal = %{
        "document_type" => "invoice",
        "invoice_number" => "P-1",
        "taxable_paise" => portal_tax * 5,
        "tax_paise" => %{@zero | "igst" => portal_tax},
        "total_paise" => portal_tax * 6
      }

      recon = %{@recon | "in_2b_not_books" => [%{"gstr2b" => portal}]}
      rows = [%{"id" => "books-1", "igst_paise" => books_tax, "flags" => []}]
      opening = %{@zero | "igst" => portal_tax}
      claim = %{@zero | "igst" => chosen_claim}
      later = %{@zero | "igst" => portal_tax - chosen_claim}
      position = ItcPosition.compute(recon, rows, %{}, [case_line(opening, claim, later, @zero)])
      return = Gstr3b.assemble(@liability, recon, position)

      assert return["itc"]["net_itc_4c"] == claim
      assert return["itc"]["rcm_4a3"] == @zero
      assert return["itc"]["reversed_4b1"] == @zero
      assert return["itc"]["reversed_4b2"] == @zero
      assert position["reported_2b_paise"] == portal_tax

      assert position["opening_outstanding_paise"] ==
               position["current_claim_paise"] + position["closing_outstanding_paise"]
    end
  end

  test "per-head Table 4 conservation and set-off hold for mixed claim, later and exclusion" do
    opening = %{"igst" => 6_000, "cgst" => 4_000, "sgst" => 4_000, "cess" => 100}
    claim = %{"igst" => 2_000, "cgst" => 2_000, "sgst" => 1_000, "cess" => 40}
    later = %{"igst" => 3_000, "cgst" => 1_000, "sgst" => 2_000, "cess" => 60}
    exclude = %{"igst" => 1_000, "cgst" => 1_000, "sgst" => 1_000, "cess" => 0}
    position = ItcPosition.compute(@recon, [], %{}, [case_line(opening, claim, later, exclude)])
    liability = %{"txval" => 100_000, "igst" => 3_000, "cgst" => 3_000, "sgst" => 3_000}
    return = Gstr3b.assemble(liability, @recon, position)

    for head <- ~w(igst cgst sgst cess) do
      assert opening[head] == claim[head] + later[head] + exclude[head]

      assert return["itc"]["rcm_4a3"][head] +
               return["itc"]["all_other_itc_4a5"][head] -
               return["itc"]["reversed_4b1"][head] -
               return["itc"]["reversed_4b2"][head] == return["itc"]["net_itc_4c"][head]
    end

    refute Gstr3b.negative_net_itc?(return)
    assert return["setoff_61"]["cash_total"] >= 0
  end
end
