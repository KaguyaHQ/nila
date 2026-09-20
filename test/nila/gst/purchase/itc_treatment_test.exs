defmodule Nila.Gst.Purchase.ItcTreatmentTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Purchase.ItcTreatment, as: T

  test "split balances every head, rather than only the total" do
    opening = %{"cgst" => 100, "sgst" => 100, "igst" => 0, "cess" => 0}

    assert {:error, :amounts_do_not_balance} =
             T.build(opening, %{
               "choice" => "split",
               "claim" => %{"cgst" => 200, "sgst" => 0, "igst" => 0, "cess" => 0},
               "later" => T.zero(),
               "exclude" => T.zero()
             })

    assert {:error, :invalid_amounts} =
             T.build(opening, %{
               "choice" => "split",
               "claim" => %{"cgst" => -1},
               "later" => T.zero(),
               "exclude" => T.zero()
             })

    assert {:error, :reason_required} =
             T.build(opening, %{"choice" => "later", "later_reason" => "other"})
  end

  test "a source correction needs review and a new review clears it" do
    original = %{"cgst" => 100, "sgst" => 100, "igst" => 0, "cess" => 10}
    {:ok, payload} = T.build(original, %{"choice" => "later", "later_reason" => "review_pending"})
    payload = Map.put(payload, "source_heads", original)

    event = %{
      id: 1,
      event_type: "treatment_decided",
      effective_client_month: %{period: "2026-08"},
      payload: payload
    }

    line = T.project(%{original | "cess" => 20}, [event], [], "2026-09")
    assert line.treatment_stale?
    assert line.outstanding_heads == %{original | "cess" => 20}
    assert line.treatment_heads["later"] == %{original | "cess" => 20}
    historical = T.project(%{original | "cess" => 20}, [event], [], "2026-08")
    assert historical.treatment_heads["later"] == original

    {:ok, revised} =
      T.build(line.outstanding_heads, %{"choice" => "later", "later_reason" => "review_pending"})

    reviewed = %{
      event
      | id: 2,
        effective_client_month: %{period: "2026-09"},
        payload: Map.put(revised, "source_heads", %{original | "cess" => 20})
    }

    refute T.project(%{original | "cess" => 20}, [event, reviewed], [], "2026-09").treatment_stale?
  end

  test "same month correction replaces the decision without counting it twice" do
    original = %{"cgst" => 100, "sgst" => 100, "igst" => 0, "cess" => 0}
    {:ok, later} = T.build(original, %{"choice" => "later", "later_reason" => "review_pending"})
    {:ok, excluded} = T.build(original, %{"choice" => "exclude", "exclude_reason" => "personal"})

    events =
      for {id, payload} <- [{1, later}, {2, excluded}],
          do: %{
            id: id,
            event_type: "treatment_decided",
            effective_client_month: %{period: "2026-08"},
            payload: payload
          }

    line = T.project(original, events, [], "2026-09")
    assert line.outstanding_heads == T.zero()
    refute line.treatment_stale?
  end
end
