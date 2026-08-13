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
end
