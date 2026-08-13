defmodule NilaWeb.Components.Gst.Month.FilingTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias NilaWeb.Components.Gst.Month.Filing

  test "offers the B2B Winman download before approval" do
    assigns = %{
      sales_month: %{client_id: Ecto.UUID.generate(), period: "2026-07", filed_at: nil},
      r1_signoff: nil,
      open_issue_count: 2,
      reviewable: false,
      completeness: :open,
      sales_intake_open: false,
      can_sign_off: false,
      derived: nil
    }

    assigns = Map.put(assigns, :readiness, Filing.gstr1_readiness(assigns))
    html = render_component(&Filing.gstr1_actions/1, assigns)

    export = html |> LazyHTML.from_fragment() |> LazyHTML.query("#gstr1-winman-b2b-export")
    button = LazyHTML.query(export, "#gstr1-download-winman-b2b")

    assert LazyHTML.text(button) =~ "Download Winman B2B"

    assert LazyHTML.attribute(button, "href") == [
             "/gstr1/#{assigns.sales_month.client_id}/2026-07/winman-b2b.xlsm"
           ]

    assert LazyHTML.text(export) =~ "Filing artifact"
    assert LazyHTML.text(export) =~ "Winman import · B2B sheet"
    assert LazyHTML.text(export) =~ "Only the B2B sheet is populated"
  end

  test "readiness keeps unresolved intake provisional after issue checks clear" do
    readiness =
      Filing.gstr1_readiness(%{
        sales_month: %{filed_at: nil},
        r1_signoff: nil,
        open_issue_count: 0,
        reviewable: true,
        sales_intake_open: true,
        can_sign_off: true
      })

    assert readiness.state == :provisional
    assert readiness.status =~ "unresolved sales packet"
    refute readiness.status =~ "Ready for approval"
  end

  test "readiness separates complete checks from the user's permission" do
    common = %{
      sales_month: %{filed_at: nil},
      r1_signoff: nil,
      open_issue_count: 0,
      reviewable: true,
      sales_intake_open: false
    }

    assert Filing.gstr1_readiness(Map.put(common, :can_sign_off, true)).state == :ready

    awaiting = Filing.gstr1_readiness(Map.put(common, :can_sign_off, false))
    assert awaiting.state == :awaiting_senior
    assert awaiting.status == "Draft checks complete — awaiting a senior"
  end

  test "a provisional 3B states the current proposed ITC instead of its pre-decision ceiling" do
    gstr3b = %{
      "liability_source" => "missing",
      "liability_31" => %{
        "a" => %{"igst" => 0, "cgst" => 0, "sgst" => 0},
        "d" => %{"igst" => 0, "cgst" => 16_338, "sgst" => 16_338}
      },
      "itc" => %{
        "rcm_4a3" => %{"igst" => 0, "cgst" => 16_338, "sgst" => 16_338},
        "all_other_itc_4a5" => %{"igst" => 1_000_000, "cgst" => 3_070_000, "sgst" => 3_069_750},
        "reversed_4b1" => %{"igst" => 0, "cgst" => 0, "sgst" => 0},
        "reversed_4b2" => %{"igst" => 0, "cgst" => 0, "sgst" => 0},
        "net_itc_4c" => %{"igst" => 1_000_000, "cgst" => 3_086_338, "sgst" => 3_086_088}
      },
      "setoff_61" => %{"cash_total" => 0}
    }

    html =
      render_component(&Filing.gstr3b_evidence/1,
        gstr3b: gstr3b,
        itc: %{"claimable_paise" => 6_836_024},
        stats: %{need_decision: 12},
        signed: false
      )

    position = html |> LazyHTML.from_fragment() |> LazyHTML.query("#gst-3b-position")

    assert LazyHTML.text(position) =~ "₹68,360.24"
    refute LazyHTML.text(position) =~ "₹71,724.26"
    assert LazyHTML.text(position) =~ "Pending GSTR-1"

    refute html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#gst-3b-filing-detail")
           |> LazyHTML.text() =~ "4C"
  end
end
