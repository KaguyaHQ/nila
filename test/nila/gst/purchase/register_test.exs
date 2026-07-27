defmodule Nila.Gst.Purchase.RegisterTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Purchase.Register

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
        "matched_tax_paise" => 90_000,
        "open_tax_paise" => 45_000
      }

      assert Register.stats(summary) == %{
               invoices: 14,
               matched: 3,
               need_decision: 9,
               taxable_paise: 500_000,
               matched_tax_paise: 90_000,
               open_tax_paise: 45_000
             }

      assert Register.need_decision(summary) == 9
    end

    test "defaults missing counts and money to zero" do
      assert Register.stats(%{}) == %{
               invoices: 0,
               matched: 0,
               need_decision: 0,
               taxable_paise: 0,
               matched_tax_paise: 0,
               open_tax_paise: 0
             }

      assert Register.need_decision(%{"buckets" => %{"in_2b_not_books" => 1}}) == 1
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
      assert Register.need_decision(summary) == 2
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
end
