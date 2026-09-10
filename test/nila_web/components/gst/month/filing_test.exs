defmodule NilaWeb.Components.Gst.Month.FilingTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias NilaWeb.Components.Gst.Month.Filing

  test "GSTR-3B becomes signable when sales checks clear without a GSTR-1 signature" do
    assigns = %{
      purchase_month: %{client_id: "client", period: "2026-07", filed_at: nil},
      sales_month: %{filed_at: nil},
      sales_reviewable: true,
      stats: %{need_decision: 0},
      can_sign_off: true,
      gstr3b_signoff: nil,
      sales_intake_open: false,
      itc: nil,
      gstr3b: nil
    }

    assert Filing.gstr3b_readiness(assigns).state == :ready
    html = render_component(&Filing.gstr3b_primary_action/1, assigns)

    assert LazyHTML.to_html(LazyHTML.query(LazyHTML.from_fragment(html), "#month-door-sign-3b")) !=
             ""

    blocked = %{assigns | sales_reviewable: false}
    assert Filing.gstr3b_readiness(blocked).state == :blocked
    html = render_component(&Filing.gstr3b_blocker_list/1, blocked)

    assert LazyHTML.text(
             LazyHTML.query(LazyHTML.from_fragment(html), "#gstr3b-blocker-r1-unreviewed")
           ) =~ "Resolve the open sales checks"
  end

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

    assert LazyHTML.attribute(link, "href") == ["/sales-bills"]
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

  test "unsigned 3B controls keep claimable ITC and provisional schedules consistent" do
    gstr3b = %{
      "liability_source" => "gstr1_derived",
      "liability_31" => %{
        "a" => %{"txval" => 10_000_000, "igst" => 0, "cgst" => 900_000, "sgst" => 900_000},
        "d" => %{"igst" => 0, "cgst" => 0, "sgst" => 0}
      },
      "itc" => %{
        "rcm_4a3" => %{"igst" => 0, "cgst" => 0, "sgst" => 0},
        "all_other_itc_4a5" => %{"igst" => 0, "cgst" => 600_000, "sgst" => 600_000},
        "reversed_4b1" => %{"igst" => 0, "cgst" => 0, "sgst" => 0},
        "reversed_4b2" => %{"igst" => 0, "cgst" => 0, "sgst" => 0},
        "net_itc_4c" => %{"igst" => 0, "cgst" => 600_000, "sgst" => 600_000}
      },
      "setoff_61" => %{
        "cash_total" => 600_000,
        "other" => %{},
        "rcm" => %{}
      }
    }

    html =
      render_component(&Filing.gstr3b_controls/1,
        gstr3b: gstr3b,
        itc: %{"claimable_paise" => 1_100_000},
        stats: %{need_decision: 1},
        signed: false,
        open_folds:
          MapSet.new(~w(gstr3b-control-itc gstr3b-control-filing-lines gstr3b-control-setoff)),
        client_id: Ecto.UUID.generate(),
        period: "2026-07"
      )

    fragment = LazyHTML.from_fragment(html)
    assert LazyHTML.text(LazyHTML.query(fragment, "#gstr3b-control-current-itc")) =~ "₹11,000.00"

    assert LazyHTML.text(LazyHTML.query(fragment, "#gstr3b-itc-provisional-difference")) =~
             "₹12,000.00"

    assert LazyHTML.text(LazyHTML.query(fragment, "#gst-3b-filing-detail-pending")) =~
             "1 purchase input remain"

    assert LazyHTML.text(LazyHTML.query(fragment, "#gst-3b-setoff-pending")) =~
             "1 purchase input remain"

    assert LazyHTML.to_html(LazyHTML.query(fragment, "#gst-3b-filing-detail")) == ""
    assert LazyHTML.to_html(LazyHTML.query(fragment, "#gst-3b-setoff-detail")) == ""
    assert LazyHTML.to_html(LazyHTML.query(fragment, "#gstr3b-itc-supporting-evidence")) == ""

    assert LazyHTML.text(LazyHTML.query(fragment, "#gstr3b-open-purchases")) =~
             "Open Purchases & ITC"
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
