defmodule NilaWeb.Components.Gst.Month.FilingTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias NilaWeb.Components.Gst.Month.Filing

  test "offers the B2B Winman download before approval" do
    assigns = %{
      sales_month: %{client_id: Ecto.UUID.generate(), period: "2026-07"},
      r1_signoff: nil,
      open_issue_count: 2,
      reviewable: false,
      completeness: :open,
      sales_intake_open: false,
      can_sign_off: false,
      derived: nil
    }

    html = render_component(&Filing.gstr1_actions/1, assigns)

    export = html |> LazyHTML.from_fragment() |> LazyHTML.query("#gstr1-winman-b2b-export")
    button = LazyHTML.query(export, "#gstr1-download-winman-b2b")

    assert LazyHTML.text(button) =~ "Download Winman B2B"

    assert LazyHTML.attribute(button, "href") == [
             "/gstr1/#{assigns.sales_month.client_id}/2026-07/winman-b2b.xlsm"
           ]

    assert LazyHTML.text(export) =~ "Only the B2B tab is populated"
  end
end
