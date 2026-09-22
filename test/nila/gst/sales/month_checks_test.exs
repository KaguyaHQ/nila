defmodule Nila.Gst.Sales.Review.MonthChecksTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Sales.Review.MonthChecks

  test "sequence evidence changes invalidate confirmations; taxpayer fetches do not" do
    issue = %{
      "code" => "sequence_gaps",
      "invoice" => nil,
      "level" => "required",
      "message" => "Missing 2"
    }

    invoice = %{
      "id" => "source-1",
      "invoice_number" => "1",
      "buyer_name" => "Buyer",
      "taxpayer_checks" => %{"status" => "pending"}
    }

    bound = MonthChecks.bind(issue, [invoice], [])
    confirmation = %{"payload" => %{"basis" => bound["basis"]}}
    assert MonthChecks.confirmed?(bound, confirmation)
    refute MonthChecks.confirmed?(bound, %{"payload" => %{}})

    for changed <- [
          Map.put(invoice, "invoice_number", "3"),
          Map.put(invoice, "buyer_name", "Corrected"),
          Map.put(invoice, "id", "new-source")
        ] do
      refute MonthChecks.confirmed?(MonthChecks.bind(issue, [changed], []), confirmation)
    end

    refreshed =
      Map.put(invoice, "taxpayer_checks", %{"status" => "fetched", "legal_name" => "Lookup"})

    assert MonthChecks.bind(issue, [refreshed], [])["basis"] == bound["basis"]
  end

  test "known labels cannot make blocking or invoice checks confirmable" do
    base = %{"code" => "pages_unaccounted", "invoice" => nil, "level" => "required"}
    assert MonthChecks.supported?(base)
    refute MonthChecks.supported?(Map.put(base, "level", "blocking"))
    refute MonthChecks.supported?(Map.put(base, "invoice", "INV-1"))
    refute MonthChecks.supported?(Map.put(base, "source_id", "source-1"))
    refute MonthChecks.supported?(Map.put(base, "source_ids", ["source-1"]))
    refute MonthChecks.supported?(Map.put(base, "code", "future_check"))
  end
end
