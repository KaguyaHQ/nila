defmodule NilaWeb.Gst.MonthLiveSalesOverviewTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures
  import NilaWeb.Gst.MonthLiveSalesHelpers, only: [confirm_all_open_issues: 1]

  alias Nila.Clients
  alias Nila.Repo
  alias Nila.TallyDevices
  alias Nila.TallyDevices.{SyncRun, SyncedVoucher}

  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    work_dump!(org, client, @period, "sales", "%PDF-1.4 fake bytes", user.id)

    %{conn: log_in_user(conn, user), org: org, client: client, user: user}
  end

  test "renders the worked sales month with issue flags", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    assert has_element?(view, "#month-page")
    assert has_element?(view, "#month-sales")
    assert has_element?(view, "#gstr1-inv-20\\/2025-26")
    assert has_element?(view, "#shell-client-switcher-trigger", "Breeze Tech")
    assert has_element?(view, "#month-verdict h1.text-h4", "Oct 2025")
    refute has_element?(view, "#month-headline")
    assert has_element?(view, "#month-deadline-sales", "GSTR-1")
    refute has_element?(view, "#month-deadline-purchase")
    refute has_element?(view, "#month-verdict", "Purchase bills not in")

    assert has_element?(view, "#gstr1-verdict h2", "GSTR-1 draft")

    assert has_element?(
             view,
             "#gstr1-required-summary",
             "1 review case before approval"
           )

    refute view |> element("#gstr1-required-summary") |> render() =~ "false"
    assert has_element?(view, "#gstr1-review-required", "Review required items")
    assert has_element?(view, "#gstr1-draft-invoices", "3 invoices in draft")
    assert has_element?(view, "#gstr1-draft-output-tax", "₹15,615.36")
    assert has_element?(view, "#gstr1-overview.sales-overview[data-state='provisional']")
    refute has_element?(view, "#month-door-sales-issues")
    assert has_element?(view, "#gstr1-inv-20\\/2025-26", "Review case")

    assert has_element?(
             view,
             "#gstr1-inv-20\\/2025-26 .whitespace-nowrap.font-mono",
             "20/2025-26"
           )

    assert has_element?(
             view,
             "#gstr1-grouped-review-cases article",
             "Invoice 20/2025-26"
           )

    assert has_element?(view, "#gstr1-grouped-review-cases article", "Current draft")
    refute has_element?(view, "#gstr1-standalone-required [data-role='issue-invoice']")

    assert has_element?(view, "#month-sales-sources", "Sales bills")
    assert has_element?(view, "#gstr1-filing-status", "Provisional")
    assert has_element?(view, "#month-exit-gstr1", "Blocked · 1 required item remains")
    refute has_element?(view, "#month-door-review-issue")

    section_ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#month-sales > [id]")
      |> LazyHTML.attribute("id")

    assert section_ids == [
             "gstr1-overview",
             "gstr1-checks-before-filing",
             "gstr1-return-controls",
             "gstr1-register",
             "gstr1-return",
             "gstr1-source-documents",
             "gstr1-handoff"
           ]
  end

  test "opens the global client switcher from a client month", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    {:ok, caltech} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Caltech",
        type: "company"
      })

    work_dump!(org, caltech, @period, "sales", "%PDF-1.4 caltech bytes", user.id)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}?track=sales")

    assert has_element?(
             view,
             "#shell-client-switcher-trigger[aria-expanded='false']",
             "Breeze Tech"
           )

    view |> element("#shell-client-switcher-trigger") |> render_click()

    assert has_element?(view, "#shell-client-switcher-trigger[aria-expanded='true']")

    assert has_element?(
             view,
             "#shell-client-switcher-sheet-focus-wrap[role='dialog']",
             "Switch client"
           )

    assert has_element?(
             view,
             "#shell-client-switcher-navigation[phx-hook='SelectableList'][data-loop='true']"
           )

    assert has_element?(
             view,
             "#client_switcher_query[role='combobox'][aria-controls='shell-client-switcher-options']"
           )

    assert has_element?(
             view,
             "#shell-client-switcher-options[role='listbox'][aria-label='Clients']"
           )

    assert has_element?(
             view,
             "button#shell-client-switcher-client-#{client.id}[data-state='selected'][aria-selected='true']",
             "Current"
           )

    assert has_element?(
             view,
             "#shell-client-switcher-client-#{caltech.id}[href*='/clients/#{caltech.id}/select']",
             "Caltech"
           )

    view
    |> form("#shell-client-switcher-search-form", %{
      "client_switcher" => %{"query" => "calt"}
    })
    |> render_change()

    assert has_element?(view, "#shell-client-switcher-client-#{caltech.id}", "Caltech")
    refute has_element?(view, "#shell-client-switcher-client-#{client.id}")

    view
    |> element("#shell-client-switcher-sheet button[phx-click='close']")
    |> render_click()

    refute has_element?(view, "#shell-client-switcher-sheet")
  end

  test "return workings disclose schedules before contributor rows", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    assert has_element?(
             view,
             "#gstr1-workings-b2b:not([open]) > summary",
             "Party-wise B2B working"
           )

    assert has_element?(view, "#gstr1-workings-b2b > summary", "output tax")
    assert has_element?(view, "#gstr1-workings-rates:not([open]) > summary", "Rate summary")
    assert has_element?(view, "#gstr1-workings-rates > summary", "taxable")

    view |> element("#gstr1-workings-b2b > summary") |> render_click()

    assert has_element?(view, "#gstr1-workings-b2b[open]")
    assert has_element?(view, "#gstr1-workings-b2b-rows")
    assert has_element?(view, "#gstr1-workings-b2b-rows .whitespace-nowrap.font-mono")
    assert has_element?(view, "#gstr1-workings-rates:not([open])")

    view |> element("#gstr1-workings-b2b > summary") |> render_click()

    assert has_element?(view, "#gstr1-workings-b2b:not([open])")
  end

  test "the proposed return shows filing sections without pipeline telemetry or false reconciliation",
       %{
         conn: conn,
         client: client
       } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    refute has_element?(view, "#gstr1-draft-reconciliation")
    refute has_element?(view, "#gstr1-reconciliation")
    refute has_element?(view, "#month-sales", "Source files received")
    refute has_element?(view, "#month-sales", "Invoice pages read")
    refute has_element?(view, "#month-sales", "Documents extracted")
    refute has_element?(view, "#month-sales", "Unique invoice numbers")
    refute has_element?(view, "#gstr1-record-confirmation")
    refute has_element?(view, "#gstr1-completeness-override-modal")
    assert has_element?(view, "#gstr1-filing-summary", "Proposed GSTR-1")
    assert has_element?(view, "#gstr1-filing-b2b", "₹86,752.00")
    assert has_element?(view, "#gstr1-hsn-signoff", "HSN summary · Table 12")
    assert has_element?(view, "#gstr1-control-hsn #gstr1-workings-hsn")
    refute has_element?(view, "#gstr1-return #gstr1-workings-hsn")
    refute has_element?(view, "#gstr1-hsn-signoff", "Difference from sales register")
    assert has_element?(view, "#gstr1-document-summary", "Documents issued · Table 13")
    assert has_element?(view, "#gstr1-document-series-1-1", "20/2025-26")
    assert has_element?(view, "#gstr1-document-series-1-1", "22/2025-26")
    assert has_element?(view, "#gstr1-verdict", "₹86,752.00")
    assert has_element?(view, "#gstr1-verdict", "₹15,615.36")
  end

  test "renders B2CS, B2CL and B2C HSN filing sections", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.{Gstr1, Months}
    period = "2026-07"

    invoice = fn number, pos, taxable, tax ->
      tax_fields =
        if pos == "33" do
          %{
            "cgst_rate" => 9,
            "cgst_amount" => tax / 2,
            "sgst_rate" => 9,
            "sgst_amount" => tax / 2
          }
        else
          %{"igst_rate" => 18, "igst_amount" => tax}
        end

      Gstr1.normalize_invoice(%{
        "data" => %{
          "document_type" => "invoice",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "unregistered",
          "place_of_supply" => pos,
          "invoice_number" => number,
          "invoice_date" => "15.07.2026",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "Unregistered buyer", "gstin" => nil},
          "line_items" => [
            Map.merge(
              %{
                "description" => "Fixture goods",
                "hsn_sac" => "8471",
                "quantity" => 1,
                "uom" => "Nos",
                "taxable_value" => taxable
              },
              tax_fields
            )
          ],
          "printed_total_taxable" => taxable,
          "printed_total_tax" => tax,
          "printed_grand_total" => taxable + tax
        }
      })
    end

    invoices = [
      invoice.("INV-B2CS", "33", 42_372.88, 7_627.12),
      invoice.("INV-B2CL", "29", 93_220.34, 16_779.66)
    ]

    {:ok, _month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period))
      })

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{period}?track=sales")

    assert has_element?(view, "#gstr1-filing-b2cs", "B2CS")
    assert has_element?(view, "#gstr1-filing-b2cl", "B2CL")
    assert has_element?(view, "#gstr1-workings-b2cs:not([open]) > summary", "B2CS working")
    assert has_element?(view, "#gstr1-workings-b2cl:not([open]) > summary", "B2CL working")
    assert has_element?(view, "#gstr1-workings-b2cl", "INV-B2CL")
    assert has_element?(view, "#gstr1-workings-hsn-b2c", "NOS")
    assert has_element?(view, "#gstr1-inv-INV-B2CS", "Unregistered")
  end

  test "every invoice renders once in the visible register with its review state", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    assert has_element?(view, "#gstr1-register:not(details)")
    assert has_element?(view, "#gstr1-register table.nila-table[data-mode='worklist']")
    assert has_element?(view, "#gstr1-register thead.text-label")
    assert has_element?(view, "#gstr1-invoices #gstr1-inv-20\\/2025-26", "Review case")
    assert has_element?(view, "#gstr1-invoices #gstr1-inv-20\\/2025-26", "No recorded action")
    assert has_element?(view, "#gstr1-invoices #gstr1-inv-21\\/2025-26")
    assert has_element?(view, "#gstr1-invoices #gstr1-inv-22\\/2025-26")
    refute has_element?(view, "#gstr1-invoices #gstr1-inv-21\\/2025-26", "Verified")
    refute has_element?(view, "#gstr1-invoices #gstr1-inv-22\\/2025-26", "Verified")
    refute has_element?(view, "#gstr1-verified")

    row_ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#gstr1-invoices tr[id^='gstr1-inv-']")
      |> LazyHTML.attribute("id")

    assert length(row_ids) == 3
  end

  test "shows a matched Tally voucher in the existing sales register without a duplicate row", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})
    {:ok, [company]} = TallyDevices.report_companies(device, [%{"name" => "Breeze Tech"}])
    client |> Ecto.Changeset.change(active_tally_company_id: company.id) |> Repo.update!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%SyncRun{
      org_id: org.id,
      device_id: device.id,
      company_id: company.id,
      status: "succeeded",
      masters_status: "succeeded",
      vouchers_status: "succeeded",
      period_start: ~D[2025-10-01],
      period_end: ~D[2025-10-31],
      started_at: now,
      completed_at: now
    })

    Repo.insert!(%SyncedVoucher{
      org_id: org.id,
      company_id: company.id,
      identity: "guid:matched-21",
      date: ~D[2025-10-10],
      voucher_type: "Sales",
      voucher_number: "21/2025-26",
      data: %{
        "party_ledger_name" => "PONMANI AND CO",
        "party_gstin" => "33AABCP9487A1ZG",
        "place_of_supply" => "33",
        "line_items" => [
          %{
            "description" => "AC service",
            "hsn_sac" => "8415",
            "taxable_value" => 12_000.0,
            "cgst_rate" => 9.0,
            "cgst_amount" => 1_080.0,
            "sgst_rate" => 9.0,
            "sgst_amount" => 1_080.0
          }
        ]
      }
    })

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    assert has_element?(view, "#gstr1-register", "1 from Tally")
    assert has_element?(view, "#gstr1-inv-21\\/2025-26", "Tally + document")

    row_ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#gstr1-invoices tr[id^='gstr1-inv-']")
      |> LazyHTML.attribute("id")

    assert length(row_ids) == 3
  end

  test "human assurance counts distinct invoices, not actions or month checks", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    assert has_element?(view, "#gstr1-human-assurance-count", "0 of 3 invoices")
    assert has_element?(view, "#gstr1-human-assurance-open", "3 have no recorded human review")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    view
    |> element("button[phx-click='resolve-invoice-issue']", "Accept the extracted lines")
    |> render_click()

    assert has_element?(view, "#gstr1-human-assurance-count", "1 of 3 invoices")
    assert has_element?(view, "#gstr1-human-assurance-open", "2 have no recorded human review")
  end

  test "the workings and single Table 12 show reviewable return figures", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    b2b = view |> element("#gstr1-workings-b2b") |> render()
    assert b2b =~ "PONMANI AND CO"
    assert b2b =~ "SIEMENS HEALTHCARE"

    assert view |> element("#gstr1-workings-rates") |> render() =~ "18%"

    hsn = view |> element("#gstr1-workings-hsn") |> render()
    assert hsn =~ "2903"
    assert hsn =~ "8415"
    assert hsn =~ "9987"
    assert has_element?(view, "#gstr1-control-hsn #gstr1-workings-hsn")
    refute has_element?(view, "#gstr1-return #gstr1-workings-hsn")

    refute has_element?(view, "#gstr1-workings-docs")
    refute has_element?(view, "#gstr1-workings", "Documents issued")

    {:ok, month} = Nila.Gst.Sales.Months.get_by_period(org.id, client.id, @period)

    assert get_in(month.derived_gstr1, [
             "doc_issue",
             "doc_det",
             Access.at(0),
             "docs",
             Access.at(0)
           ]) == %{
             "num" => 1,
             "from" => "20/2025-26",
             "to" => "22/2025-26",
             "totnum" => 3,
             "cancel" => 0,
             "net_issue" => 3
           }
  end

  test "an aggregate's contributor rows name their invoices and carry their share", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    row = view |> element("#gstr1-workings-rate-18-inv-22-2025-26") |> render()
    assert row =~ "22/2025-26"
    assert row =~ "SIEMENS HEALTHCARE"
    assert row =~ "10,200.00"
  end

  test "the return workings and Table 12 remain visible through re-renders", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    assert has_element?(view, "#gstr1-return", "Return workings")
    assert has_element?(view, "#gstr1-workings-b2b")
    assert has_element?(view, "#gstr1-workings-b2b .text-ui.tabular-nums", "output tax")
    refute has_element?(view, "#gstr1-workings-b2b .text-context")
    assert has_element?(view, "#gstr1-workings-rates")
    assert has_element?(view, "#gstr1-control-hsn .text-ui.tabular-nums", "combinations")
    assert has_element?(view, "#gstr1-control-hsn #gstr1-workings-hsn")
    refute has_element?(view, "#gstr1-return #gstr1-workings-hsn")
    refute has_element?(view, "#gstr1-workings-docs")

    confirm_all_open_issues(view)

    assert has_element?(view, "#gstr1-control-hsn #gstr1-workings-hsn")
  end

  test "an opened bucket survives an unrelated re-render", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    contrib = "#gstr1-workings-rate-18-inv-22-2025-26"
    assert view |> element(contrib) |> render() =~ "hidden"

    view |> element("#gstr1-workings-rate-18") |> render_click()
    refute view |> element(contrib) |> render() =~ "hidden"

    # Confirming an issue re-renders the whole section. Expansion is server
    # state, so the bucket the reviewer opened is still open.
    confirm_all_open_issues(view)
    refute view |> element(contrib) |> render() =~ "hidden"

    view |> element("#gstr1-workings-rate-18") |> render_click()
    assert view |> element(contrib) |> render() =~ "hidden"
  end

  test "a contributor row opens the invoice modal it names", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    refute has_element?(view, "#gstr1-evidence-modal")

    # The same inum appears in several subsections; scope to one.
    view
    |> element("#gstr1-workings-rate-18-inv-22-2025-26")
    |> render_click()

    assert has_element?(view, "#gstr1-evidence-modal")
    assert view |> element("#gstr1-evidence-modal") |> render() =~ "SIEMENS HEALTHCARE"
  end
end
