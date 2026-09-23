defmodule NilaWeb.Components.Gst.Month.FilingTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias NilaWeb.Components.Gst.Month.Filing

  test "keeps final handoffs unavailable while required issues remain" do
    assigns = %{
      sales_month: %{client_id: Ecto.UUID.generate(), period: "2026-07", filed_at: nil},
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
    assert LazyHTML.to_html(export) == ""

    assert LazyHTML.to_html(
             html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#gstr1-tally-export")
           ) == ""
  end

  test "offers XML and the existing sales-bills posting workflow once checks pass" do
    assigns = %{
      sales_month: %{
        client_id: Ecto.UUID.generate(),
        period: "2026-07",
        filed_at: nil,
        filing_arn: nil
      },
      open_issue_count: 0,
      reviewable: true,
      sales_intake_open: false,
      can_sign_off: true,
      derived: nil,
      handoff: handoff(),
      tally_companies: [
        %{id: 7, name: "Nila", device: %{name: "Accounts PC"}}
      ]
    }

    assigns = Map.put(assigns, :readiness, Filing.gstr1_readiness(assigns))
    html = render_component(&Filing.gstr1_actions/1, assigns)

    export = html |> LazyHTML.from_fragment() |> LazyHTML.query("#gstr1-tally-export")
    download = LazyHTML.query(export, "#gstr1-download-tally")
    link = LazyHTML.query(export, "#gstr1-open-sales-bills")

    assert LazyHTML.attribute(download, "href") == [
             "/gstr1/#{assigns.sales_month.client_id}/2026-07/tally.xml"
           ]

    assert LazyHTML.text(download) =~ "Download Tally XML"

    assert LazyHTML.attribute(link, "href") == [
             "/gst/#{assigns.sales_month.client_id}/2026-07/sales"
           ]

    assert LazyHTML.text(link) =~ "Open sales bills"
    assert LazyHTML.to_html(LazyHTML.query(export, "#gstr1-send-tally-form")) == ""
    assert LazyHTML.text(export) =~ "GL sales vouchers"
    assert LazyHTML.text(export) =~ "GST return metadata is not included"
  end

  test "offers the ready Tally XML to operators" do
    assigns = %{
      sales_month: %{
        client_id: Ecto.UUID.generate(),
        period: "2026-07",
        filed_at: nil,
        filing_arn: nil
      },
      open_issue_count: 0,
      reviewable: true,
      sales_intake_open: false,
      can_sign_off: false,
      derived: nil,
      handoff: handoff()
    }

    assigns = Map.put(assigns, :readiness, Filing.gstr1_readiness(assigns))
    html = render_component(&Filing.gstr1_actions/1, assigns)

    export = html |> LazyHTML.from_fragment() |> LazyHTML.query("#gstr1-tally-export")

    assert LazyHTML.text(LazyHTML.query(export, "#gstr1-download-tally")) =~ "Download Tally XML"
    refute LazyHTML.text(LazyHTML.query(export, "#gstr1-send-tally")) =~ "Send to TallyPrime"
  end

  test "the ready Winman handoff names the complete manifest" do
    assigns = %{
      sales_month: %{
        client_id: Ecto.UUID.generate(),
        period: "2026-07",
        filed_at: nil,
        filing_arn: nil
      },
      open_issue_count: 0,
      reviewable: true,
      sales_intake_open: false,
      can_sign_off: true,
      derived: nil,
      handoff: handoff()
    }

    assigns = Map.put(assigns, :readiness, Filing.gstr1_readiness(assigns))
    html = render_component(&Filing.gstr1_actions/1, assigns)
    fragment = LazyHTML.from_fragment(html)
    manifest = LazyHTML.query(fragment, "#gstr1-handoff-manifest")

    assert LazyHTML.text(manifest) =~ "8 B2B workbook rows"
    assert LazyHTML.text(manifest) =~ "From 7 B2B invoices"
    assert LazyHTML.text(manifest) =~ "1 supported document omitted"
    assert LazyHTML.text(manifest) =~ "CDNR 1"
    assert LazyHTML.text(manifest) =~ "2 confirmations"
    assert LazyHTML.text(manifest) =~ "1 correction"
    assert LazyHTML.text(manifest) =~ "1 duplicate copy"
    assert LazyHTML.text(manifest) =~ "0 review cases"
    assert LazyHTML.text(manifest) =~ "₹7,12,393.00 taxable"
    assert LazyHTML.text(manifest) =~ "₹1,28,230.74 tax"

    assert LazyHTML.text(LazyHTML.query(fragment, "#gstr1-winman-b2b-export")) =~
             "Only the B2B sheet is populated"
  end

  test "readiness keeps unresolved intake provisional after issue checks clear" do
    readiness =
      Filing.gstr1_readiness(%{
        sales_month: %{filed_at: nil},
        open_issue_count: 0,
        reviewable: true,
        sales_intake_open: true,
        can_sign_off: true
      })

    assert readiness.state == :provisional
    assert readiness.status =~ "sales packet remains unresolved"
    refute readiness.status =~ "Ready for approval"
  end

  test "readiness depends on checks without requiring senior approval" do
    common = %{
      sales_month: %{filed_at: nil},
      open_issue_count: 0,
      reviewable: true,
      sales_intake_open: false
    }

    assert Filing.gstr1_readiness(Map.put(common, :can_sign_off, true)).state == :ready

    awaiting = Filing.gstr1_readiness(Map.put(common, :can_sign_off, false))
    assert awaiting.state == :ready
    assert awaiting.status == "Working files ready"
  end

  defp handoff do
    %{
      included_documents: 8,
      included_b2b_invoices: 7,
      omitted_documents: 1,
      omitted_by_table: [%{table: "cdnr", label: "CDNR", count: 1}],
      confirmations: 2,
      corrections: 1,
      duplicates_excluded: 1,
      review_cases_held: 0,
      blockers_held: 0,
      unsupported_held: 0,
      taxable: 712_393.0,
      output_tax: 128_230.74
    }
  end
end
