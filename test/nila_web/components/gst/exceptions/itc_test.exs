defmodule NilaWeb.Components.Gst.Exceptions.ItcTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NilaWeb.Components.Gst.Exceptions.Itc

  defp bridge(itc) do
    render_component(&itc_bridge/1, itc: itc, id: "b")
  end

  test "shows source 2B separately from the reviewed opening and current claim" do
    html =
      bridge(%{
        "reported_2b_paise" => 12_000,
        "opening_outstanding_paise" => 15_000,
        "later_paise" => 5_000,
        "excluded_paise" => 3_000,
        "pending_paise" => 3_000,
        "current_claim_paise" => 4_000
      })

    assert html =~ ~s(id="b-reported-context")
    assert html =~ "Reported in GSTR-2B this period"
    assert html =~ "carried credit is shown in the opening balance"
    assert html =~ ~s(id="b-opening")
    assert html =~ "Opening outstanding ITC"
    assert html =~ ~s(id="b-later")
    assert html =~ "Less: claim later"
    assert html =~ ~s(id="b-excluded")
    assert html =~ ~s(id="b-pending")
    assert html =~ ~s(id="b-claimable")
    assert html =~ "Claim this period"
    assert html =~ "40.00"
    refute html =~ "Less: supplier credit notes"
    refute html =~ "Less: blocked credits"
  end

  test "zero treatment deductions do not add empty rows" do
    html =
      bridge(%{
        "reported_2b_paise" => 10_000,
        "opening_outstanding_paise" => 10_000,
        "later_paise" => 0,
        "excluded_paise" => 0,
        "pending_paise" => 0,
        "current_claim_paise" => 10_000
      })

    refute html =~ ~s(id="b-later")
    refute html =~ ~s(id="b-excluded")
    refute html =~ ~s(id="b-pending")
    assert html =~ ~s(id="b-claimable")
  end

  test "does not invent a bridge for a frozen snapshot without treatment amounts" do
    assert bridge(%{"reported_2b_paise" => 12_000, "claimable_paise" => 12_000}) =~
             ~r/\A\s*\z/
  end
end
