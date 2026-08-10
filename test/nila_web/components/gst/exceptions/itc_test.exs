defmodule NilaWeb.Components.Gst.Exceptions.ItcTest do
  @moduledoc """
  The ITC bridge is the one panel drawn as an equation, which makes it the panel
  a reviewer trusts to check the others. These tests hold it to that: every line
  it prints has to produce the line below it.
  """
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NilaWeb.Components.Gst.Exceptions.Itc

  # A month whose books and 2B disagree: one supply the vendor never reported
  # (books-only, ₹5,000) and one the 2B values higher than the books
  # (₹10,000 in books, ₹12,000 on the portal).
  defp stats do
    %{
      total_tax_paise: 15_000,
      unreported_by_vendor_tax_paise: 5_000,
      unreported_by_vendor_known?: true
    }
  end

  defp position(overrides \\ %{}) do
    Map.merge(
      %{
        "reported_2b_paise" => 12_000,
        "claimable_paise" => 12_000,
        "pending_decision_paise" => 0,
        "blocked_in_ceiling_paise" => 0,
        "awaiting_document_paise" => 0,
        "blocks" => []
      },
      overrides
    )
  end

  defp bridge(itc, stats \\ stats()) do
    render_component(&itc_bridge/1, itc: itc, stats: stats, id: "b")
  end

  test "names the basis difference instead of printing a subtraction that does not land" do
    html = bridge(position())

    assert html =~ ~s(id="b-books-itc")
    assert html =~ ~s(id="b-not-in-2b")

    # 15,000 − 5,000 = 10,000, but the ceiling is 12,000. Without this line the
    # bridge printed A − B above a C that was not A − B.
    assert html =~ ~s(id="b-basis-residual")
    assert html =~ "the 2B&#39;s figure where it differs from your books"
    assert html =~ "+"
    assert html =~ "20.00"
  end

  test "no residual line when the books and the 2B agree" do
    html = bridge(position(%{"reported_2b_paise" => 10_000, "claimable_paise" => 10_000}))

    refute html =~ ~s(id="b-basis-residual")
  end

  test "supplier credit notes are a named 4B(2) deduction" do
    html =
      bridge(
        position(%{
          "reported_2b_paise" => 18_000,
          "credit_note_reversal_applied_paise" => 3_600,
          "claimable_paise" => 14_400
        }),
        %{
          total_tax_paise: 21_600,
          net_itc_effect_paise: 14_400,
          unreported_by_vendor_tax_paise: 0,
          unreported_by_vendor_known?: true
        }
      )

    assert html =~ ~s(id="b-credit-notes")
    assert html =~ "less supplier credit notes"
    assert html =~ "Positive face values"
    assert html =~ "4B(2)"
    assert html =~ "36.00"
  end

  test "withheld credit gets a line of its own between the ceiling and the claim" do
    html =
      bridge(
        position(%{
          "claimable_paise" => 0,
          "awaiting_document_paise" => 0,
          "unsubstantiated_withheld_paise" => 12_000
        })
      )

    # Previously the bridge printed the ceiling directly above a claim of ₹0
    # with nothing between them: the entire month's credit vanished silently.
    assert html =~ ~s(id="b-withheld")
    assert html =~ "less credit the client holds no bill for"
    assert html =~ "4B(2)"

    assert html =~ ~s(id="b-claimable")
  end

  test "renders nothing for a snapshot frozen before the partition existed" do
    assert bridge(%{"claimable_paise" => 12_000}) =~ ~r/\A\s*\z/
  end
end
