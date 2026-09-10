defmodule Nila.Gst.Extraction.InvoiceDataTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Extraction.InvoiceData

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

      {repaired, repairs} = InvoiceData.repair_gstins(data, :purchase, @client)

      assert repaired["buyer"]["gstin"] == @client
      assert repaired["seller"]["gstin"] == @damaged
      assert [%{"field" => "buyer.gstin", "basis" => "known_client"}] = repairs
    end

    test "on a sales pile it is the seller" do
      data = %{
        "supplier" => %{"gstin" => @damaged},
        "bill_to" => %{"gstin" => @damaged}
      }

      {repaired, repairs} = InvoiceData.repair_gstins(data, :sales, @client)

      assert repaired["supplier"]["gstin"] == @client
      assert repaired["bill_to"]["gstin"] == @damaged
      assert [%{"field" => "supplier.gstin", "basis" => "known_client"}] = repairs
    end
  end
end
