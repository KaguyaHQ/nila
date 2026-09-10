defmodule Nila.Gst.Extraction.InvoiceRepairsTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.LineAmounts
  alias Nila.Gst.Extraction.InvoiceRepairs

  describe "repairing a scan-damaged GSTIN against the known client" do
    # The scanner read the state code 33 as 03. The grammar cannot object — a
    # digit is legal there — so only the check digit fails, and only the
    # client's own number can settle it. The client sits on a different side of
    # the bill in each pile: buyer on what they bought, seller on what they
    # sold. Snapping the other side would rewrite a counterparty's identity, and
    # on a sales pile that counterparty changes every bill.
    @damaged "03AEWPH4158J1Z3"
    @client "33AEWPH4158J1Z3"

    test "on a purchase pile the client's own side is the buyer" do
      data = %{"seller" => %{"gstin" => @damaged}, "buyer" => %{"gstin" => @damaged}}

      {repaired, repairs} = InvoiceRepairs.repair_gstins(data, :purchase, @client)

      assert repaired["buyer"]["gstin"] == @client
      assert repaired["seller"]["gstin"] == @damaged
      assert [%{"field" => "buyer.gstin", "basis" => "known_client"}] = repairs
    end

    test "on a sales pile it is the seller" do
      data = %{
        "supplier" => %{"gstin" => @damaged},
        "bill_to" => %{"gstin" => @damaged}
      }

      {repaired, repairs} = InvoiceRepairs.repair_gstins(data, :sales, @client)

      assert repaired["supplier"]["gstin"] == @client
      assert repaired["bill_to"]["gstin"] == @damaged
      assert [%{"field" => "supplier.gstin", "basis" => "known_client"}] = repairs
    end
  end

  describe "discard_redundant_printed_taxable/1" do
    test "keeps distinct printed values within the arithmetic tolerance" do
      line = %{
        "printed_line_amount" => 100,
        "printed_taxable_value" => 100.02,
        "printed_line_total" => 118,
        "igst_rate" => 18,
        "igst_amount" => 18
      }

      assert {^line, nil} = InvoiceRepairs.discard_redundant_printed_taxable(line)
      assert LineAmounts.taxable_value(line) == 100.02
    end

    test "drops a duplicate only when row arithmetic independently proves exclusive pricing" do
      line = %{
        "printed_line_amount" => 20_500,
        "printed_line_total" => 24_190,
        "printed_taxable_value" => 20_500,
        "line_amount_tax_inclusion" => "exclusive",
        "cgst_rate" => 9,
        "cgst_amount" => 1_845,
        "sgst_rate" => 9,
        "sgst_amount" => 1_845
      }

      assert {cleaned, repair} = InvoiceRepairs.discard_redundant_printed_taxable(line)
      assert cleaned["printed_taxable_value"] == nil
      assert repair["from"] == 20_500
      assert repair["basis"] == "redundant_with_arithmetically_exclusive_line_amount"
    end

    test "keeps equal candidates when arithmetic cannot establish their relationship" do
      line = %{
        "printed_line_amount" => 20_500,
        "printed_taxable_value" => 20_500,
        "line_amount_tax_inclusion" => "exclusive"
      }

      assert {^line, nil} = InvoiceRepairs.discard_redundant_printed_taxable(line)
    end
  end
end
