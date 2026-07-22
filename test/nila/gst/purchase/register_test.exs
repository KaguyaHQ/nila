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
        "accepted_unmatched" => 2
      }

      assert Register.stats(summary) == %{invoices: 14, matched: 3, need_decision: 9}
      assert Register.need_decision(summary) == 9
    end

    test "defaults missing counts to zero" do
      assert Register.stats(%{}) == %{invoices: 0, matched: 0, need_decision: 0}
      assert Register.need_decision(%{"buckets" => %{"in_2b_not_books" => 1}}) == 1
    end
  end
end
