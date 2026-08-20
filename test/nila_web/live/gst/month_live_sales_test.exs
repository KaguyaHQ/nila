defmodule NilaWeb.Gst.MonthLiveSalesTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.Purchase.Months, as: ClientMonths
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
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-page")
    assert has_element?(view, "#month-sales")
    assert has_element?(view, "#gstr1-inv-20\\/2025-26")
    assert has_element?(view, "#month-verdict h1.text-h4", "Breeze Tech")
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

  test "switches between clients in the same period without losing the workpaper", %{
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

    {:ok, other_period} =
      Clients.create_client(%{
        org_id: org.id,
        name: "August Only",
        type: "company"
      })

    work_dump!(org, caltech, @period, "sales", "%PDF-1.4 caltech bytes", user.id)
    work_dump!(org, other_period, "2025-08", "sales", "%PDF-1.4 august bytes", user.id)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}?track=sales")

    assert has_element?(view, "#open-client-switcher[aria-expanded='false']", "Breeze Tech")

    view |> element("#open-client-switcher") |> render_click()

    assert has_element?(view, "#open-client-switcher[aria-expanded='true']")
    assert has_element?(view, "#client-switcher-focus-wrap[role='dialog']", "Switch client")

    assert has_element?(
             view,
             "#client-switcher-navigation[phx-hook='SelectableList'][data-loop='true']"
           )

    assert has_element?(
             view,
             "#client_switcher_query[role='combobox'][aria-controls='client-switcher-options']"
           )

    assert has_element?(view, "#client-switcher-options[role='listbox'][aria-label='Clients']")

    assert has_element?(
             view,
             "button#client-switcher-client-#{client.id}[phx-click='close-client-switcher'][data-state='selected'][aria-selected='true']",
             "Current"
           )

    assert has_element?(
             view,
             "#client-switcher-client-#{caltech.id}[href='/gst/#{caltech.id}/#{@period}?track=sales']",
             "Caltech"
           )

    assert has_element?(
             view,
             "a#client-switcher-client-#{caltech.id}[role='option'][aria-selected='false'][tabindex='-1'][data-selectable-option]"
           )

    refute has_element?(view, "#client-switcher-client-#{other_period.id}")

    view
    |> element("#client-switcher-client-#{client.id}")
    |> render_click()

    refute has_element?(view, "#client-switcher")
    assert has_element?(view, "#open-client-switcher[aria-expanded='false']")

    view |> element("#open-client-switcher") |> render_click()

    view
    |> form("#client-switcher-search-form", %{"client_switcher" => %{"query" => "calt"}})
    |> render_change()

    assert has_element?(view, "#client-switcher-client-#{caltech.id}", "Caltech")
    refute has_element?(view, "#client-switcher-client-#{client.id}")

    view
    |> element("#client-switcher button[phx-click='close-client-switcher']")
    |> render_click()

    refute has_element?(view, "#client-switcher")
    assert has_element?(view, "#open-client-switcher[aria-expanded='false']")

    view |> element("#open-client-switcher") |> render_click()

    view
    |> form("#client-switcher-search-form", %{
      "client_switcher" => %{"query" => "no-such-client"}
    })
    |> render_submit()

    assert has_element?(view, "#client-switcher", "No clients match this search.")
    assert has_element?(view, "#client_switcher_query[value='no-such-client']")
    refute has_element?(view, "#client-switcher-options [data-selectable-option]")

    view
    |> form("#client-switcher-search-form", %{"client_switcher" => %{"query" => "calt"}})
    |> render_submit()

    assert_redirect(view, ~p"/gst/#{caltech.id}/#{@period}?track=sales")
  end

  test "return workings disclose schedules before contributor rows", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

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
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

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

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")

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
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

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
    company = company |> Ecto.Changeset.change(client_id: client.id) |> Repo.update!()
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

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

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
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-human-assurance-count", "0 of 3 invoices")
    assert has_element?(view, "#gstr1-human-assurance-open", "3 have no recorded human review")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    view
    |> element("button[phx-click='resolve-invoice-issue']", "Accept the extracted lines")
    |> render_click()

    assert has_element?(view, "#gstr1-human-assurance-count", "1 of 3 invoices")
    assert has_element?(view, "#gstr1-human-assurance-open", "2 have no recorded human review")
  end

  test "a bill carrying both IGST and CGST/SGST is stopped and its cost named", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    period = "2025-12"

    # Seller TN, buyer KA — interstate. One line billed IGST, another CGST/SGST.
    # The totals tally, so every arithmetic check passes and the return files
    # ₹1,800 IGST; the ₹450 + ₹450 the client charged simply disappears.
    invoices = [
      Gstr1.normalize_invoice(%{
        "data" => %{
          "invoice_number" => "40/2025-26",
          "invoice_date" => "04.12.2025",
          "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{"name" => "PONMANI AND CO", "gstin" => "29AAVCS8021P1ZB"},
          "line_items" => [
            %{"taxable_value" => 5000, "igst_rate" => 18, "igst_amount" => 900},
            %{
              "taxable_value" => 5000,
              "cgst_rate" => 9,
              "cgst_amount" => 450,
              "sgst_rate" => 9,
              "sgst_amount" => 450
            }
          ],
          "printed_total_taxable" => 10_000.0,
          "printed_total_tax" => 1800.0,
          "printed_grand_total" => 11_800.0
        }
      })
    ]

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period)),
        issues: Gstr1.validation_issues(invoices),
        summary: %{"invoice_count" => 1, "issue_count" => 1}
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")

    assert has_element?(view, "#gstr1-grouped-review-cases", "Invoice 40/2025-26")
    assert has_element?(view, "#gstr1-grouped-review-cases", "Review")

    assert has_element?(view, "#gstr1-required-summary", "1 review case")
    refute has_element?(view, "#month-door-sign-r1")

    # The modal has to say what it costs, because the totals agree and no other
    # figure on the page moves.
    view |> element("#gstr1-inv-40\\/2025-26") |> render_click()
    modal = view |> element("#gstr1-evidence-modal") |> render()

    assert modal =~ "one supply has one place of supply"
    assert modal =~ "buyer&#39;s 2B will not match the bill they hold"
  end

  test "a sequence gap is confessed in the summary and account before any card opens", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    period = "2025-11"

    invoices =
      for n <- [30, 31, 33] do
        Gstr1.normalize_invoice(%{
          "data" => %{
            "invoice_number" => "#{n}/2025-26",
            "invoice_date" => "04.11.2025",
            "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
            "buyer" => %{"name" => "PONMANI AND CO", "gstin" => "33AABCP9487A1ZG"},
            "line_items" => [
              %{
                "taxable_value" => 1000,
                "cgst_rate" => 9,
                "cgst_amount" => 90,
                "sgst_rate" => 9,
                "sgst_amount" => 90
              }
            ]
          }
        })
      end

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period)),
        issues: Gstr1.validation_issues(invoices),
        summary: %{"invoice_count" => 3, "issue_count" => 1}
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")

    assert has_element?(view, "#gstr1-return-controls summary")
    assert has_element?(view, "#gstr1-required-summary", "1 required check before approval")
    refute has_element?(view, "#gstr1-required-summary", "false")

    assert has_element?(view, "#gstr1-checks-before-filing", "Missing invoice numbers")
    assert has_element?(view, "#gstr1-checks-before-filing", "32/2025-26")
    refute has_element?(view, "#gstr1-draft-reconciliation", "Sequence gaps")

    view
    |> element("#gstr1-standalone-required button[phx-click='confirm_issue']")
    |> render_click()

    assert has_element?(view, "#gstr1-human-assurance-count", "0 of 3 invoices")
  end

  test "an ordinary month asks nothing about cess", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    # The stub bills refrigeration work. Nothing on them can carry cess, so the
    # reviewer is never asked and the healthy check stays silent.
    refute has_element?(view, "#gstr1-draft-reconciliation", "Cess")
    refute has_element?(view, "#gstr1-checks-before-filing", "csamt 0")
    refute has_element?(view, "#gstr1-required-summary", "blocker")
  end

  test "a tobacco line blocks the month, and nothing on the page clears it", %{
    conn: conn,
    org: org,
    client: client
  } do
    seed_cess_line!(org, client)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-checks-before-filing", "csamt 0")
    refute has_element?(view, "#gstr1-draft-reconciliation", "Cess")
    assert has_element?(view, "#gstr1-required-summary", "1 blocker")
    refute has_element?(view, "#month-door-sign-r1")

    # Answering every other check does not move it: nothing here is an exit.
    confirm_all_open_issues(view)

    assert has_element?(view, "#gstr1-checks-before-filing", "csamt 0")
    refute has_element?(view, "#month-door-sign-r1")
  end

  test "a blocker nobody can answer is still named in the count that gates", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    # An export still has no supported derivation, so no reviewer action clears
    # it. It asks for no work, which is exactly why blockers must remain in the
    # count even when the review queue has no answer.
    invoices =
      Enum.map(month.invoices, fn
        %{"invoice_number" => "21/2025-26"} = invoice ->
          Map.put(invoice, "document", %{"export" => true})

        invoice ->
          invoice
      end)

    month |> Ecto.Changeset.change(invoices: invoices) |> Nila.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(
             view,
             "#gstr1-required-summary",
             "1 review case · 1 blocker before approval"
           )

    refute view |> element("#gstr1-required-summary") |> render() =~ "false"
    refute has_element?(view, "#month-door-sign-r1")
  end

  test "a blocker-only sales requirement never renders a boolean", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.{Gstr1, Months}

    period = "2026-08"

    invoice =
      Gstr1.normalize_invoice(%{
        "data" => %{
          "document_type" => "invoice",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "registered",
          "place_of_supply" => "33",
          "invoice_number" => "EXP-1",
          "invoice_date" => "15.08.2026",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "Registered buyer", "gstin" => "33AABCP9487A1ZG"},
          "line_items" => [
            %{
              "description" => "Fixture service",
              "hsn_sac" => "9987",
              "taxable_value" => 1_000,
              "cgst_rate" => 9,
              "cgst_amount" => 90,
              "sgst_rate" => 9,
              "sgst_amount" => 90
            }
          ],
          "printed_total_taxable" => 1_000,
          "printed_total_tax" => 180,
          "printed_grand_total" => 1_180
        }
      })
      |> Map.put("document", %{"export" => true})

    {:ok, _month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: [invoice],
        issues: Gstr1.validation_issues([invoice]),
        derived_gstr1: Gstr1.derive([invoice], Gstr1.production_header(client.gstin, period))
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")

    assert has_element?(view, "#gstr1-required-summary", "1 blocker before approval")
    refute view |> element("#gstr1-required-summary") |> render() =~ "false"
  end

  test "a registered credit note reaches CDNR workings and no longer blocks the month", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    invoices =
      Enum.map(month.invoices, fn
        %{"invoice_number" => "21/2025-26"} = invoice ->
          invoice
          |> Map.put("document_type", "credit_note")
          |> Map.put("document", %{"credit_note" => true})

        invoice ->
          invoice
      end)

    month |> Ecto.Changeset.change(invoices: invoices) |> Nila.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-workings-cdnr", "21/2025-26")
    assert has_element?(view, "#gstr1-filing-cdnr", "9B registered credit and debit notes")
    assert has_element?(view, "#gstr1-document-summary", "Credit notes")
    refute has_element?(view, "#gstr1-checks-before-filing", "credit note")
  end

  test "a registered debit note reaches CDNR with a positive liability effect", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    invoices =
      Enum.map(month.invoices, fn
        %{"invoice_number" => "21/2025-26"} = invoice ->
          invoice
          |> Map.put("document_type", "debit_note")
          |> Map.put("document", %{"debit_note" => true})

        invoice ->
          invoice
      end)

    month |> Ecto.Changeset.change(invoices: invoices) |> Nila.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-workings-cdnr", "21/2025-26")
    assert has_element?(view, "#gstr1-workings-cdnr", "Debit")
    assert has_element?(view, "#gstr1-filing-cdnr", "9B registered credit and debit notes")
    assert has_element?(view, "#gstr1-document-summary", "Debit notes")
    refute has_element?(view, "#gstr1-checks-before-filing", "debit note")
  end

  test "the month shows the object being approved, and claims nothing it cannot check", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-filing-summary", "Proposed GSTR-1")
    assert has_element?(view, "#gstr1-filing-status", "Provisional")
    assert has_element?(view, "#gstr1-filing-b2b", "B2B regular")

    # The page describes this month's populated filing sections. Generic
    # capability boundaries belong in required work only when this month hits one.
    refute has_element?(view, "#gstr1-filing-capability")
    refute has_element?(view, "#gstr1-filing-summary", "Exports, SEZ")

    confirm_all_open_issues(view)

    assert has_element?(view, "#gstr1-filing-status", "Ready for approval")
    assert has_element?(view, "#month-door-sign-r1")
  end

  # Taxable B2C invoices are supported, but notes to unregistered recipients
  # belong in CDNUR. Until that table exists they must block rather than leak into
  # registered CDNR or be confirmed away.
  test "an unregistered note blocks the month and names the way out", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    invoices =
      Enum.map(month.invoices, fn invoice ->
        if invoice["invoice_number"] == "21/2025-26" do
          invoice
          |> Map.put("buyer_gstin", nil)
          |> Map.put("recipient_registration", "unregistered")
          |> Map.put("place_of_supply", "33")
          |> Map.put("document_type", "credit_note")
          |> Map.put("document", %{
            "credit_note" => true,
            "debit_note" => false,
            "extracted_type" => "credit_note"
          })
        else
          invoice
        end
      end)

    {:ok, _month} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, @period))
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-checks-before-filing", "no cdnur table")
    assert has_element?(view, "#gstr1-blocked-next-move", "manually on the portal")
    assert has_element?(view, "#gstr1-blocked-next-move", "Breeze Tech")

    # No amount of confirming clears it, and approval stays out of reach.
    confirm_all_open_issues(view)

    assert has_element?(view, "#gstr1-blocked-next-move")
    refute has_element?(view, "#month-door-sign-r1")
  end

  test "unseen HSN codes render as one advisory block that never gates approval", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.{Gstr1, Months}

    invoice = fn number, code ->
      Gstr1.normalize_invoice(%{
        "data" => %{
          "invoice_number" => number,
          "invoice_date" => "04.12.2025",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "Silver Buyer", "gstin" => "33AABCP9487A1ZG"},
          "line_items" => [
            %{
              "description" => "Widget",
              "hsn_sac" => code,
              "taxable_value" => 10_000,
              "cgst_rate" => 9,
              "cgst_amount" => 900,
              "sgst_rate" => 9,
              "sgst_amount" => 900
            }
          ],
          "printed_total_taxable" => 10_000,
          "printed_total_tax" => 1_800,
          "printed_grand_total" => 11_800
        }
      })
    end

    upsert = fn period, invoices ->
      {:ok, month} =
        Months.upsert(%{
          org_id: org.id,
          client_id: client.id,
          period: period,
          state: "worked",
          invoices: invoices,
          derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period)),
          issues: Gstr1.validation_issues(invoices)
        })

      month
    end

    # History this client has filed, then a month carrying two codes it never has.
    upsert.("2025-11", [invoice.("100/2025-26", "84159000")])

    upsert.("2025-12", [
      invoice.("137/2025-26", "28043000"),
      invoice.("138/2025-26", "29033990")
    ])

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/2025-12")

    assert has_element?(view, "#gstr1-hsn-new-codes", "2 of 2 codes are new for this client")
    assert has_element?(view, "#gstr1-workings-hsn-28043000-18", "New")
    assert has_element?(view, "#gstr1-workings-hsn-29033990-18", "New")
    refute has_element?(view, "#gstr1-hsn-new-code-rows")
    refute has_element?(view, "#gstr1-hsn-signoff", "Printed on the bill")
    refute has_element?(view, "#gstr1-verdict", "advisories")

    # Context, not work: no confirm affordance, not in the gating clause, and
    # approval is reachable without anyone clearing it.
    refute has_element?(view, "#gstr1-hsn-new-codes button[phx-click='confirm_issue']")
    refute has_element?(view, "#gstr1-checks-before-filing")

    assert has_element?(view, "#gstr1-filing-status", "Ready for approval")
    assert has_element?(view, "#month-door-sign-r1")
  end

  test "Table 12 flags multiple rates, shows official descriptions, and expands affected rows", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Hsn.{Entry, Release}
    alias Nila.Gst.Sales.{Gstr1, Months}

    release =
      %Release{}
      |> Release.changeset(%{
        source_name: "GST portal HSN master",
        file_sha256: Base.encode16(:crypto.strong_rand_bytes(32)),
        status: "active",
        observed_at: DateTime.utc_now(),
        activated_at: DateTime.utc_now()
      })
      |> Nila.Repo.insert!()

    Nila.Repo.insert!(%Entry{
      release_id: release.id,
      code: "71069290",
      description: "Other semi-manufactured forms of silver",
      kind: "hsn",
      digits: 8,
      has_children: false
    })

    period = "2025-12"

    invoices =
      for {number, rate} <- [{"137/2025-26", 3}, {"142/2025-26", 18}] do
        half_rate = rate / 2

        Gstr1.normalize_invoice(%{
          "data" => %{
            "invoice_number" => number,
            "invoice_date" => "04.12.2025",
            "seller" => %{"gstin" => client.gstin},
            "buyer" => %{"name" => "Silver Buyer", "gstin" => "33AABCP9487A1ZG"},
            "line_items" => [
              %{
                "description" => "Silver rod",
                "hsn_sac" => "71069290",
                "taxable_value" => 10_000,
                "cgst_rate" => half_rate,
                "cgst_amount" => 10_000 * half_rate / 100,
                "sgst_rate" => half_rate,
                "sgst_amount" => 10_000 * half_rate / 100
              }
            ]
          }
        })
      end

    {:ok, _month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period)),
        issues: Gstr1.validation_issues(invoices)
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")

    # The issue is asserted once, in "Before filing"; the Table 12 card points
    # at it rather than drawing a second copy with different buttons.
    issue =
      Enum.find(
        Nila.Gst.Sales.Resolutions.workings(
          elem(Months.get_by_period(org.id, client.id, period), 1)
        ).issues,
        &(&1["code"] == "hsn_multiple_rates")
      )

    card = "#gstr1-required-#{:erlang.phash2({"hsn_multiple_rates|71069290", issue["message"]})}"

    assert has_element?(view, card, "HSN/SAC 71069290 appears at 3% and 18%")
    refute has_element?(view, "#gstr1-hsn-signoff", "HSN/SAC 71069290 appears at 3% and 18%")
    assert has_element?(view, "#gstr1-hsn-signoff", "HSN check in required work")
    assert has_element?(view, "#gstr1-workings-hsn", "Other semi-manufactured forms of silver")

    refute has_element?(view, "#gstr1-workings-hsn-71069290-3 .rotate-90")
    refute has_element?(view, card, "Confirm from records")

    view |> element("#{card} a", "Review HSN rows") |> render_click()

    assert has_element?(view, "#gstr1-workings-hsn-71069290-3 .rotate-90")
    assert has_element?(view, "#gstr1-workings-hsn-71069290-18 .rotate-90")
    assert has_element?(view, card, "Confirm from records")

    view |> element("#{card} button", "Confirm from records") |> render_click()

    refute has_element?(view, card)
  end

  test "duplicate review compares every source and excludes only the extra copies", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    original = Enum.find(month.invoices, &(&1["invoice_number"] == "21/2025-26"))
    copy_two = Map.put(original, "id", "#{original["id"]}_copy_2")
    copy_three = Map.put(original, "id", "#{original["id"]}_copy_3")
    invoices = month.invoices ++ [copy_two, copy_three]

    {:ok, _month} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, @period))
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(
             view,
             "#gstr1-checks-before-filing button[phx-click='open-duplicate-review']"
           )

    view |> element("button[phx-click='open-duplicate-review']") |> render_click()

    assert has_element?(view, "#gstr1-duplicate-review-modal", "Duplicate invoice 21/2025-26")
    assert has_element?(view, "#gstr1-duplicate-source-#{original["id"]}")
    assert has_element?(view, "#gstr1-duplicate-source-#{copy_two["id"]}")
    assert has_element?(view, "#gstr1-duplicate-source-#{copy_three["id"]}")

    view
    |> element(
      "button[phx-click='resolve-duplicate-copies'][phx-value-source='#{original["id"]}']"
    )
    |> render_click()

    refute has_element?(view, "#gstr1-duplicate-review-modal")
    refute has_element?(view, "button[phx-click='open-duplicate-review']")
    refute has_element?(view, "#gstr1-draft-reconciliation")
    assert has_element?(view, "#gstr1-document-summary", "Documents issued · Table 13")
    assert has_element?(view, "#gstr1-document-series-1-1", "3")
    assert has_element?(view, "#gstr1-inv-#{copy_two["id"]}", "Duplicate copy")
    assert has_element?(view, "#gstr1-inv-#{copy_three["id"]}", "Duplicate copy")
  end

  test "the invoice row owns issue review without a detached next-issue action", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    {:ok, month} = Nila.Gst.Sales.Months.get_by_period(org.id, client.id, @period)
    [invoice | _] = Nila.Gst.Sales.Resolutions.workings(month).active_invoices

    refute has_element?(view, "#month-door-sales-issues")
    refute has_element?(view, "#month-door-review-issue")
    refute has_element?(view, "#gstr1-evidence-modal")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    assert_patch(
      view,
      "/gst/#{client.id}/#{@period}/review/sales?item=#{invoice["id"]}&scope=needs_you"
    )

    assert has_element?(view, "#gstr1-evidence-modal")
    assert has_element?(view, "#gstr1-checks button", "Accept the extracted lines")

    assert has_element?(
             view,
             "#gstr1-rate-validation-scope",
             "imported taxable-goods rate candidates are checked independently"
           )
  end

  test "opening, adjacent navigation, and Done patch without unmounting MonthLive", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    invoices =
      Enum.map(month.invoices, fn
        %{"invoice_number" => "21/2025-26"} = invoice ->
          Map.put(invoice, "printed_grand_total", 1)

        invoice ->
          invoice
      end)

    {:ok, updated} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, @period))
      })

    [first, second | _] = Nila.Gst.Sales.Resolutions.workings(updated).active_invoices
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    month_pid = view.pid

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    assert_patch(
      view,
      "/gst/#{client.id}/#{@period}/review/sales?item=#{first["id"]}&scope=needs_you"
    )

    view |> element("#gstr1-review-next") |> render_click()

    assert_patch(
      view,
      "/gst/#{client.id}/#{@period}/review/sales?item=#{second["id"]}&scope=needs_you"
    )

    view |> element("#gstr1-review-previous") |> render_click()

    assert_patch(
      view,
      "/gst/#{client.id}/#{@period}/review/sales?item=#{first["id"]}&scope=needs_you"
    )

    view |> element("#sales-review button[phx-click='done']") |> render_click()
    assert_patch(view, "/gst/#{client.id}/#{@period}?track=sales")
    assert view.pid == month_pid
    refute has_element?(view, "#gstr1-evidence-modal")
  end

  test "the invoice review URL survives refresh and Done returns to the register", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, month} = Nila.Gst.Sales.Months.get_by_period(org.id, client.id, @period)
    [invoice | _] = Nila.Gst.Sales.Resolutions.workings(month).active_invoices

    review_path =
      "/gst/#{client.id}/#{@period}/review/sales?item=#{invoice["id"]}&scope=needs_you"

    {:ok, view, _html} = live(conn, review_path)

    assert has_element?(view, "#gstr1-evidence-modal")
    assert has_element?(view, "#gstr1-review-header", "1 to answer")
    assert has_element?(view, "#gstr1-review-header", "Filing blocked")
    assert has_element?(view, "#gstr1-review-previous[disabled]", "Previous")
    assert has_element?(view, "#gstr1-review-next[disabled]", "Next")
    assert has_element?(view, "[data-review-target='gstr1-line-total']")
    assert has_element?(view, "[data-review-target='gstr1-line-total'] span", "1")

    view |> element("#sales-review button[phx-click='done']") |> render_click()

    assert_patch(view, "/gst/#{client.id}/#{@period}?track=sales")
    refute has_element?(view, "#gstr1-evidence-modal")

    assert view |> element("#gstr1-inv-20\\/2025-26") |> render() =~
             "nila-sales-register-row-reviewed"
  end

  test "previous and next flagged invoice stay inside the route-backed review queue", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    invoices =
      Enum.map(month.invoices, fn
        %{"invoice_number" => "21/2025-26"} = invoice ->
          Map.put(invoice, "printed_grand_total", 1)

        invoice ->
          invoice
      end)

    {:ok, updated_month} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, @period))
      })

    next_id =
      updated_month.invoices
      |> Enum.find(&(&1["invoice_number"] == "21/2025-26"))
      |> Map.fetch!("id")

    first_id =
      updated_month.invoices
      |> Enum.find(&(&1["invoice_number"] == "20/2025-26"))
      |> Map.fetch!("id")

    path = "/gst/#{client.id}/#{@period}/review/sales?item=#{first_id}&scope=needs_you"
    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#gstr1-review-next:not([disabled])", "Next")
    view |> element("#gstr1-review-next") |> render_click()

    assert_patch(
      view,
      "/gst/#{client.id}/#{@period}/review/sales?item=#{next_id}&scope=needs_you"
    )

    assert has_element?(view, "#gstr1-evidence-modal-title", "21/2025-26")
    assert has_element?(view, "#gstr1-review-previous:not([disabled])")
  end

  test "same-kind issue chips are distinct and point to their own evidence", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    period = "2025-12"

    line = %{
      "description" => "Service",
      "taxable_value" => 1.06,
      "cgst_rate" => 9,
      "cgst_amount" => 0.10,
      "sgst_rate" => 9,
      "sgst_amount" => 0.10
    }

    invoice =
      Gstr1.normalize_invoice(%{
        "data" => %{
          "invoice_number" => "44/2026-27",
          "invoice_date" => "04.12.2025",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "Philips India", "gstin" => "33AABCP9487A1ZG"},
          "line_items" => List.duplicate(line, 4)
        }
      })

    invoices = [invoice]
    issues = Gstr1.validation_issues(invoices)

    assert Enum.count(issues, &(&1["code"] == "rounding_variance")) == 2

    {:ok, review_month} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        issues: issues,
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period))
      })

    [review_invoice] = Nila.Gst.Sales.Resolutions.workings(review_month).active_invoices

    path =
      "/gst/#{client.id}/#{period}/review/sales?item=#{review_invoice["id"]}&scope=all"

    {:ok, view, _html} = live(conn, path)

    # Both are `info` — Nila settled them itself — so the modal counts what the
    # register counts, and neither offers an action that would change nothing.
    assert has_element?(view, "#gstr1-review-header", "Nothing left to answer")
    assert has_element?(view, "#gstr1-review-header", "CGST rounding difference")
    assert has_element?(view, "#gstr1-review-header", "SGST rounding difference")
    assert has_element?(view, "#gstr1-evidence-modal", "explained by per-line rounding, accepted")
    refute has_element?(view, "#gstr1-evidence-modal button", "Keep extracted value")

    targets =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#gstr1-review-header button[data-review-target]")
      |> LazyHTML.attribute("data-review-target")

    assert length(targets) == 2
    assert length(Enum.uniq(targets)) == 2
    Enum.each(targets, &assert(has_element?(view, "##{&1}")))
  end

  test "clicking an invoice shows its issues in the evidence modal", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    assert has_element?(view, "#gstr1-evidence-modal")
    assert has_element?(view, "#gstr1-evidence-modal [id^='gstr1-issue-'] p")
    assert render(view) =~ "Bill total doesn&#39;t tally"
    assert has_element?(view, "#gstr1-checks dt", "Printed bill total")
    assert has_element?(view, "#gstr1-checks dt", "Sum of extracted lines")
    # The difference is why the card is open, so it is a term, not subtraction
    # left to the reader.
    assert has_element?(view, "#gstr1-checks dt", "Difference")
  end

  test "the invoice modal shows the extracted read beside validation-judged checks", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-21\\/2025-26") |> render_click()

    assert has_element?(view, "#gstr1-line-items")
    modal = view |> element("#gstr1-evidence-modal") |> render()

    # The full read: description, HSN, rate, taxable, tax split.
    assert modal =~ "AC service"
    assert modal =~ "8415"
    assert modal =~ "18%"
    # Total first, split persistent beneath it — not a hover tooltip.
    assert modal =~ "2,160.00"
    assert modal =~ "CGST 1,080.00 · SGST 1,080.00"

    # Checks render as the arithmetic the bill printed, judged by validation.
    assert modal =~ "12,000.00 × 18% = 2,160.00"
    assert modal =~ "CGST 1,080.00 = SGST 1,080.00"
    assert modal =~ "grand total: lines 14,160.00 = printed 14,160.00"
  end

  test "a failed check is its issue card rendered in place, not duplicated below", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    # The failing grand-total check renders the confirmable issue inside the
    # checks block — one judge, one rendering.
    assert has_element?(view, "#gstr1-checks button", "Accept the extracted lines")

    modal = view |> element("#gstr1-evidence-modal") |> render()
    # One compact header shortcut and one issue card; the issue is not repeated
    # in a detached section below the checks.
    assert length(String.split(modal, "Bill total doesn&#39;t tally")) == 3
  end

  test "opening an invoice marks its row read for the session", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert view |> element("#gstr1-inv-21\\/2025-26") |> render() =~ "font-medium"

    view |> element("#gstr1-inv-21\\/2025-26") |> render_click()
    view |> element("#sales-review button[phx-click='done']") |> render_click()

    row = view |> element("#gstr1-inv-21\\/2025-26") |> render()
    refute row =~ "font-medium"
    assert row =~ "text-ink-muted"
  end

  test "the workings and single Table 12 show reviewable return figures", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

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
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    row = view |> element("#gstr1-workings-rate-18-inv-22-2025-26") |> render()
    assert row =~ "22/2025-26"
    assert row =~ "SIEMENS HEALTHCARE"
    assert row =~ "10,200.00"
  end

  test "the return workings and Table 12 remain visible through re-renders", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

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
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

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
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute has_element?(view, "#gstr1-evidence-modal")

    # The same inum appears in several subsections; scope to one.
    view
    |> element("#gstr1-workings-rate-18-inv-22-2025-26")
    |> render_click()

    assert has_element?(view, "#gstr1-evidence-modal")
    assert view |> element("#gstr1-evidence-modal") |> render() =~ "SIEMENS HEALTHCARE"
  end

  test "a signed month renders its workings from the snapshot", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#month-door-sign-r1") |> render_click()

    assert has_element?(view, "#gstr1-workings-b2b")
    assert has_element?(view, "#gstr1-handoff-manifest", "3 B2B workbook rows")
    assert has_element?(view, "#gstr1-handoff-manifest", "0 review cases")
    assert has_element?(view, "#gstr1-winman-b2b-export", "Winman B2B sheet")
    assert view |> element("#gstr1-workings-b2b") |> render() =~ "PONMANI AND CO"
  end

  test "approved Winman manifest matches B2B export rows and discloses omitted sections", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    alias Nila.Gst.Filing.WinmanGstr1
    alias Nila.Gst.Sales.{Gstr1, Months, Resolutions}

    period = "2026-07"

    registered =
      Gstr1.normalize_invoice(%{
        "data" => %{
          "document_type" => "invoice",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "registered",
          "place_of_supply" => "33",
          "invoice_number" => "B2B-1",
          "invoice_date" => "15.07.2026",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "Registered buyer", "gstin" => "33AABCP9487A1ZG"},
          "line_items" => [
            %{
              "description" => "Fixture goods",
              "hsn_sac" => "8471",
              "taxable_value" => 1_000,
              "cgst_rate" => 2.5,
              "cgst_amount" => 25,
              "sgst_rate" => 2.5,
              "sgst_amount" => 25
            },
            %{
              "description" => "Fixture service",
              "hsn_sac" => "9987",
              "taxable_value" => 500,
              "cgst_rate" => 9,
              "cgst_amount" => 45,
              "sgst_rate" => 9,
              "sgst_amount" => 45
            }
          ],
          "printed_total_taxable" => 1_500,
          "printed_total_tax" => 140,
          "printed_grand_total" => 1_640
        }
      })
      |> Map.put("id", "b2b-original")

    duplicate = Map.put(registered, "id", "b2b-duplicate")

    b2cs =
      Gstr1.normalize_invoice(%{
        "data" => %{
          "document_type" => "invoice",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "unregistered",
          "place_of_supply" => "33",
          "invoice_number" => "B2CS-1",
          "invoice_date" => "16.07.2026",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "Cash buyer", "gstin" => nil},
          "line_items" => [
            %{
              "description" => "Fixture goods",
              "hsn_sac" => "8471",
              "taxable_value" => 200,
              "cgst_rate" => 9,
              "cgst_amount" => 18,
              "sgst_rate" => 9,
              "sgst_amount" => 18
            }
          ],
          "printed_total_taxable" => 200,
          "printed_total_tax" => 36,
          "printed_grand_total" => 236
        }
      })
      |> Map.put("id", "b2cs-one")

    invoices = [registered, duplicate, b2cs]

    {:ok, month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period))
      })

    assert {:ok, [_excluded]} =
             Resolutions.exclude_duplicate_copies(month, registered["id"], user.id)

    answer_sales_issues!(month, user.id)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")
    assert has_element?(view, "#month-door-sign-r1")
    view |> element("#month-door-sign-r1") |> render_click()

    assert has_element?(view, "#gstr1-handoff-manifest", "2 B2B workbook rows")
    assert has_element?(view, "#gstr1-handoff-manifest", "From 1 B2B invoice")

    assert has_element?(
             view,
             "#gstr1-handoff-manifest",
             "1 supported document omitted from this B2B workbook version · B2CS 1"
           )

    assert has_element?(view, "#gstr1-handoff-manifest", "1 duplicate copy")
    assert has_element?(view, "#gstr1-handoff-manifest", "₹1,500.00 taxable · ₹140.00 tax")

    {:ok, signed_month} = Months.get_by_period(org.id, client.id, period)
    projection = Resolutions.effective_workings(signed_month)
    assert {:ok, manifest} = WinmanGstr1.export_manifest(projection)

    export_conn =
      get(conn, ~p"/gstr1/#{client.id}/#{period}/winman-b2b.xlsm")

    workbook = response(export_conn, 200)
    {:ok, entries} = :zip.extract(workbook, [:memory])

    b2b_sheet =
      Map.new(entries, fn {path, bytes} -> {List.to_string(path), bytes} end)
      |> Map.fetch!("xl/worksheets/sheet2.xml")

    exported_rows =
      ~r/<row r="(\d+)"/
      |> Regex.scan(b2b_sheet, capture: :all_but_first)
      |> Enum.count(fn [row] -> String.to_integer(row) >= 6 end)

    assert manifest.included_documents == exported_rows
    assert manifest.included_documents == 2
    assert manifest.duplicates_excluded == 1
    assert manifest.omitted_documents == 1
    assert_in_delta manifest.taxable, 1_500, 0.001
    assert_in_delta manifest.output_tax, 140, 0.001
  end

  test "a month signed before levels were mandatory renders as it did then", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Filing.Signoffs
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#month-door-sign-r1") |> render_click()

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    {:ok, signoff} = Signoffs.latest_gstr1_signoff(month.id)

    # Rewind the frozen issues to the pre-classification shape: `"warning"` for
    # compliance checks and no level at all for arithmetic ones. Signed history
    # is never migrated, so the read path has to carry it.
    legacy =
      Enum.map(signoff.snapshot["issues"], fn issue ->
        case issue["level"] do
          "required" -> Map.put(issue, "level", "warning")
          "advisory" -> Map.put(issue, "level", "warning")
          _settled_or_blocking -> Map.delete(issue, "level")
        end
      end)

    signoff
    |> Ecto.Changeset.change(snapshot: Map.put(signoff.snapshot, "issues", legacy))
    |> Nila.Repo.update!()

    {:ok, legacy_view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    # Everything was resolved before signing, so no legacy level may resurrect a
    # check, and the approved draft still renders.
    assert has_element?(legacy_view, "#gstr1-verdict", "GSTR-1 approved")
    refute has_element?(legacy_view, "#gstr1-checks-before-filing")
    assert legacy_view |> element("#gstr1-workings-b2b") |> render() =~ "PONMANI AND CO"
  end

  test "confirming an issue resolves it; undo reopens it", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    {:ok, month} = Nila.Gst.Sales.Months.get_by_period(org.id, client.id, @period)
    [invoice | _] = Nila.Gst.Sales.Resolutions.workings(month).active_invoices
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    view
    |> element("button[phx-click='resolve-invoice-issue']", "Accept the extracted lines")
    |> render_click()

    assert has_element?(view, "#gstr1-what-changed", "Confirmation · invoice 20/2025-26")
    assert has_element?(view, "#gstr1-what-changed", "totals did not change")

    resolved_path =
      "/gst/#{client.id}/#{@period}/review/sales?item=#{invoice["id"]}&scope=all"

    {:ok, resolved, _html} = live(conn, resolved_path)
    assert render(resolved) =~ "Resolved by #{user.name}"
    assert render(resolved) =~ "Accepted extracted line total"

    resolved
    |> element("#gstr1-checks button[phx-click='undo']", "Undo")
    |> render_click()

    {:ok, reopened, _html} = live(conn, resolved_path)
    refute render(reopened) =~ "Resolved by #{user.name}"
  end

  test "Nila states a position, its basis, and what it files — and freezes it", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    modal = view |> element("#gstr1-evidence-modal") |> render()

    # Three parts, never two: what Nila would do, what it observed to think so,
    # and what that puts in the return.
    assert modal =~ "Nila&#39;s read"
    assert modal =~ "Accept the extracted lines"
    assert modal =~ "only the printed bill total disagrees"
    assert modal =~ "Files "

    # And the position is the button, not a sentence above one. Naming the
    # action in prose and then offering buttons of equal weight makes the
    # reviewer match the two by eye — a position you have to locate is a
    # paragraph. The action string appears once, and it is what you click.
    assert has_element?(
             view,
             "button[phx-click='resolve-invoice-issue']",
             "Accept the extracted lines"
           )

    refute view
           |> element("#gstr1-evidence-modal [id$='-proposal']")
           |> render() =~ "Accept the extracted lines"

    view
    |> element("button[phx-click='resolve-invoice-issue']", "Accept the extracted lines")
    |> render_click()

    # What the reviewer was shown is now part of the record, so a later rule
    # change cannot rewrite what this screen claimed Nila advised.
    {:ok, month} = Nila.Gst.Sales.Months.get_by_period(org.id, client.id, @period)

    frozen =
      month.id
      |> Nila.Gst.Sales.Resolutions.list()
      |> Enum.find_value(& &1.payload["proposal"])

    assert frozen["action"] == "Accept the extracted lines"
    assert frozen["rule_version"]
    assert frozen["basis"] =~ "only the printed bill total disagrees"
    assert frozen["effect"]["schema_version"] == 1
    assert frozen["effect"]["kind"] == "filing_result"
    assert frozen["effect"]["amounts"]["tax_paise"] > 0
  end

  test "the three tax figures are named apart, and the action states what it files", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    # The register reads the extraction and says so; the workings read the
    # recomputation and say so. "Tax" alone named all three. Column labels live
    # in the <thead>, which sits outside the <tbody> the id is on — so these
    # assert against the enclosing sections.
    # The column names what the figure is before where it came from: it sits
    # immediately after Taxable, so a bare "Sum of extracted lines" read as a
    # second take on the taxable value rather than as the tax.
    assert has_element?(view, "#gstr1-register th", "POS")
    assert has_element?(view, "#gstr1-inv-20\\/2025-26", "33")
    assert has_element?(view, "#gstr1-register th", "Extracted GST")
    assert has_element?(view, "#gstr1-register-basis.text-ui", "per-rate recomputation")
    refute has_element?(view, "#gstr1-register-basis.text-context")
    assert has_element?(view, "#gstr1-workings-basis.text-ui", "what this return files")
    refute has_element?(view, "#gstr1-workings-basis.text-context")
    assert has_element?(view, "#gstr1-workings-b2b th", "Output tax")
    assert has_element?(view, "#gstr1-workings-rates th", "Output tax")
    assert has_element?(view, "#gstr1-workings-hsn th", "Output tax")
    refute has_element?(view, "#gstr1-workings-b2b th", "GSTR-1 tax")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    # The modal's mismatch card compares two readings of the document, and
    # neither of them is filed — so the card says what accepting actually puts
    # in the return.
    modal = view |> element("#gstr1-evidence-modal") |> render()
    assert modal =~ "Files "
    assert modal =~ "tax on "
    assert modal =~ "taxable"
  end

  test "correcting a flagged field re-derives and clears the issue", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    view
    |> element("button[phx-value-field='printed_grand_total']", "Correct")
    |> render_click()

    view
    |> element("form[phx-submit='save_correct']")
    |> render_submit(%{
      "correction" => %{"field" => "printed_grand_total", "value" => "76171.36"}
    })

    refute render(view) =~ "Bill total doesn&#39;t tally"
  end

  test "historical filed-return differences are centralized, attributed, and locked when signed",
       %{conn: conn, org: org, client: client, user: user} do
    alias Nila.Gst.Sales.Months, as: SalesMonths
    alias Nila.Gst.Sales.Resolutions, as: SalesResolutions

    # No filed return, no comparison — live months are untouched.
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    refute has_element?(view, "#gstr1-filed-comparison")

    # The filed return is the derived one with invoice 21's taxable moved:
    # exactly one field disagrees, and ours is right.
    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    filed =
      update_in(month.derived_gstr1, ["b2b"], fn parties ->
        Enum.map(parties, fn party ->
          update_in(party, ["inv"], fn invs ->
            Enum.map(invs, fn
              %{"inum" => "21/2025-26"} = inv ->
                put_in(inv, ["itms", Access.at(0), "itm_det", "txval"], 13_000.0)

              inv ->
                inv
            end)
          end)
        end)
      end)

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        filed_gstr1: filed
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    # Differences live in one historical block; agreements stay silent.
    assert view |> element("#gstr1-filed-comparison") |> render() =~ "1 differ"
    assert length(String.split(render(view), ~s(phx-click="accept_difference"))) == 2

    target = "invoice_item|33AABCP9487A1ZG|21/2025-26|18|txval"

    row =
      view
      |> element("#gstr1-filed-comparison button[phx-value-target='#{target}']")
      |> render()

    assert row =~ "Ours is right"
    refute has_element?(view, "#gstr1-workings-b2b button[phx-value-target='#{target}']")

    body = render(view)
    assert body =~ "ours 12,000.00"
    assert body =~ "filed 13,000.00"

    # Accepting records an attributed, append-only resolution.
    view |> element("button[phx-click='accept_difference']") |> render_click()

    assert render(view) =~ "Accepted — ours is right"

    accepted = Enum.filter(SalesResolutions.list(month.id), &(&1.verb == "accept_difference"))
    assert [%{target: ^target, decided_by_id: decided_by}] = accepted
    assert decided_by == user.id

    # Undo returns the difference to open.
    view |> element("button[phx-click='undo'][phx-value-target='#{target}']") |> render_click()
    assert has_element?(view, "button[phx-click='accept_difference']")

    view |> element("button[phx-click='accept_difference']") |> render_click()

    # An approved month still shows the historical comparison from the snapshot,
    # but the wall hides the verbs.
    confirm_all_open_issues(view)
    view |> element("#month-door-sign-r1") |> render_click()

    assert has_element?(view, "#gstr1-diff-summary")
    assert render(view) =~ "Accepted — ours is right"
    refute has_element?(view, "button[phx-click='accept_difference']")
    refute has_element?(view, "button[phx-click='undo'][phx-value-target='#{target}']")
  end

  test "document-series differences survive without a documents-issued table", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    filed =
      put_in(
        month.derived_gstr1,
        ["doc_issue", "doc_det", Access.at(0), "docs", Access.at(0), "cancel"],
        1
      )

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        filed_gstr1: filed
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(
             view,
             "#gstr1-filed-comparison",
             "Invoice series · Cancelled: ours 0 · filed 1"
           )

    refute has_element?(view, "#gstr1-workings-docs")
  end

  test "a correction ripples the changed workings nodes and leaves the rest quiet", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    period = "2025-12"

    invoices = [
      # The tax amounts disagree with the rate, so the line's fields are
      # flagged and taxable_value is correctable through the modal.
      Gstr1.normalize_invoice(%{
        "data" => %{
          "invoice_number" => "40/2025-26",
          "invoice_date" => "04.12.2025",
          "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{"name" => "PONMANI AND CO", "gstin" => "33AABCP9487A1ZG"},
          "line_items" => [
            %{
              "taxable_value" => 1000,
              "hsn_sac" => "8415",
              "cgst_rate" => 9,
              "cgst_amount" => 100,
              "sgst_rate" => 9,
              "sgst_amount" => 90
            }
          ]
        }
      }),
      Gstr1.normalize_invoice(%{
        "data" => %{
          "invoice_number" => "41/2025-26",
          "invoice_date" => "06.12.2025",
          "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{"name" => "SIEMENS HEALTHCARE", "gstin" => "33AAVCS8021P1ZM"},
          "line_items" => [
            %{
              "taxable_value" => 2000,
              "hsn_sac" => "2903",
              "cgst_rate" => 9,
              "cgst_amount" => 180,
              "sgst_rate" => 9,
              "sgst_amount" => 180
            }
          ]
        }
      })
    ]

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period)),
        issues: Gstr1.validation_issues(invoices),
        summary: %{"invoice_count" => 2, "issue_count" => 1}
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")

    refute render(view) =~ "workings-ripple"

    view |> element("#gstr1-inv-40\\/2025-26") |> render_click()

    view
    |> element("button[phx-value-field='line_items[0].printed_taxable_value']", "Correct")
    |> render_click()

    view
    |> element("form[phx-submit='save_correct']")
    |> render_submit(%{
      "correction" => %{
        "field" => "line_items[0].printed_taxable_value",
        "value" => "1500"
      }
    })

    _ = :sys.get_state(view.pid)

    assert has_element?(
             view,
             "#gstr1-what-changed",
             "Correction · invoice 40/2025-26 · Line items[0] printed taxable value"
           )

    assert has_element?(view, "#gstr1-what-changed", "Proposed GSTR-1 changed from")

    # The nodes the re-derivation changed glow: party, rate bucket, HSN row,
    # and the month total in the account.
    assert view |> element("#gstr1-workings-party-33AABCP9487A1ZG") |> render() =~
             "workings-ripple"

    assert view |> element("#gstr1-workings-rate-18") |> render() =~ "workings-ripple"
    assert view |> element("#gstr1-workings-hsn-8415-18") |> render() =~ "workings-ripple"
    assert view |> element("#gstr1-verdict") |> render() =~ "workings-ripple"

    refute has_element?(view, "#gstr1-draft-reconciliation")
    assert has_element?(view, "#gstr1-filing-b2b", "₹3,500.00")
    assert has_element?(view, "#gstr1-filing-status", "Provisional")

    # The other party's numbers did not move, so its node stays quiet.
    refute view |> element("#gstr1-workings-party-33AAVCS8021P1ZM") |> render() =~
             "workings-ripple"

    refute view |> element("#gstr1-workings-hsn-2903-18") |> render() =~ "workings-ripple"

    # A resolution that changes no derived number clears the glow entirely.
    view
    |> element(
      "button[phx-click='resolve-invoice-issue'][phx-value-target$=':cgst_sgst_unequal']"
    )
    |> render_click()

    refute render(view) =~ "workings-ripple"
  end

  # Puts a chewing-tobacco line on invoice 22/2025-26, the one bill in the stub
  # with a single line, so a cess test has a candidate to answer about.
  defp seed_cess_line!(org, client) do
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    invoices =
      Enum.map(month.invoices, fn
        %{"invoice_number" => "22/2025-26"} = invoice ->
          put_in(invoice, ["line_items", Access.at(0), "hsn_sac"], "24039910")

        invoice ->
          invoice
      end)

    month |> Ecto.Changeset.change(invoices: invoices) |> Nila.Repo.update!()
  end

  defp confirm_all_open_issues(view) do
    # Month-level issues stay on the working paper; invoice issues live in SalesLive.
    for invoice <- ["20/2025-26"] do
      view |> element("#gstr1-inv-#{String.replace(invoice, "/", "\\/")}") |> render_click()

      while_confirmable(view)

      view
      |> element("#sales-review button[phx-click='done']")
      |> render_click()
    end

    while_confirmable(view)
  end

  defp while_confirmable(view) do
    cond do
      has_element?(view, "button[phx-click='resolve-invoice-issue']") ->
        view
        |> element("button[phx-click='resolve-invoice-issue']:first-of-type")
        |> render_click()

        while_confirmable(view)

      has_element?(view, "button[phx-click='confirm_issue']") ->
        view |> element("button[phx-click='confirm_issue']:first-of-type") |> render_click()
        while_confirmable(view)

      true ->
        :ok
    end
  end

  test "owner signs a reviewed month; the wall blocks decisions; reopen lifts it", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)

    assert has_element?(view, "#month-door-sign-r1", "Approve GSTR-1")
    assert has_element?(view, "#gstr1-overview[data-state='ready']")
    view |> element("#month-door-sign-r1") |> render_click()

    assert has_element?(view, "#gstr1-overview[data-state='approved']")
    assert has_element?(view, "#gstr1-verdict", "Approved output tax")
    assert has_element?(view, "#gstr1-draft-invoices", "in approved return")
    assert has_element?(view, "#gstr1-filing-summary", "Approved GSTR-1")
    assert has_element?(view, "#month-exit-gstr1")
    assert has_element?(view, "#gstr1-invoices #gstr1-inv-20\\/2025-26")
    assert has_element?(view, "#gstr1-workings-b2b")
    refute has_element?(view, "#gstr1-primary-handoff")
    assert has_element?(view, "#month-exit-gstr1", "Approved by")
    assert has_element?(view, "#gstr1-guide-download-json[download]", "Download GST JSON")
    assert has_element?(view, "#month-exit-gstr1", "Approved by")
    refute has_element?(view, "#month-exit-gstr1", "Draft version")
    refute has_element?(view, "#gstr1-download-json")
    assert has_element?(view, "#month-exit-gstr1 a[target='_blank'][rel='noopener']")
    assert has_element?(view, "#gstr1-filed-arn")
    refute has_element?(view, "#month-door-sign-r1")
    refute has_element?(view, "button[phx-click='confirm_issue']")

    view |> element("#gstr1-reopen-signoff") |> render_click()

    refute has_element?(view, "#month-exit-gstr1", "Approved by")
    assert has_element?(view, "#month-door-sign-r1")
  end

  test "marking a signed GSTR-1 filed records the ARN and hides reopen", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#month-door-sign-r1") |> render_click()

    view
    |> element("#gstr1-mark-filed")
    |> render_submit(%{"arn" => "AA331025000001"})

    assert has_element?(view, "#gstr1-overview[data-state='filed']")
    assert has_element?(view, "#gstr1-verdict", "Approved output tax")
    assert has_element?(view, "#gstr1-draft-invoices", "in approved return")
    assert has_element?(view, "#gstr1-filing-summary", "Filed GSTR-1")
    assert has_element?(view, "#gstr1-filed-note")
    assert has_element?(view, "#gstr1-invoices #gstr1-inv-20\\/2025-26")
    assert has_element?(view, "#gstr1-workings-b2b")
    assert render(view) =~ "AA331025000001"
    refute has_element?(view, "#gstr1-mark-filed")
    refute has_element?(view, "#gstr1-reopen-signoff")
  end

  test "a member cannot see the sign-off button", %{org: org, client: client} do
    member = Nila.AccountsFixtures.user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, member.id, "member")
    conn = log_in_user(build_conn(), member)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)

    refute has_element?(view, "#month-door-sign-r1")
    assert has_element?(view, "#gstr1-overview[data-state='awaiting_senior']")
    assert has_element?(view, "#gstr1-filing-status", "Draft checks complete — awaiting a senior")
    assert has_element?(view, "#month-exit-gstr1", "Ready · A senior must approve this return")
  end

  test "an in-flight dump appears and clears through the month subscription", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{period: @period, kind: "purchase", file_keys: ["dumps/purchase.pdf"]}
      )

    ClientMonths.broadcast_progress(
      org.id,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", :extracting}
    )

    assert has_element?(view, "#month-dump-#{dump.id}", "Extracting")

    Dumps.mark_extracted(dump, [])

    ClientMonths.broadcast_progress(
      org.id,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase",
       {:done, client.id, @period, []}}
    )

    refute has_element?(view, "#month-dump-#{dump.id}")
  end

  test "a held straggler shows on the workbench; release reworks the month", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#month-door-sign-r1") |> render_click()

    straggler = work_dump!(org, client, @period, "sales", "%PDF-1.4 late")

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    assert has_element?(view, "#month-dump-#{straggler.id}")
    refute has_element?(view, "#month-dump-release-#{straggler.id}")

    view |> element("#gstr1-reopen-signoff") |> render_click()
    assert has_element?(view, "#month-dump-release-#{straggler.id}")

    view |> element("#month-dump-release-#{straggler.id}") |> render_click()

    assert [job] = all_enqueued(worker: Nila.Gst.Intake.DumpWorker)
    assert job.args["dump_id"] == straggler.id
  end

  # A failed packet is concrete unresolved intake, not a request for a generic
  # client attestation. It blocks until a senior deliberately stops waiting.
  test "a failed sales packet blocks the month until a senior stops waiting for it", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{period: @period, kind: "sales", file_keys: ["dumps/unreadable.pdf"]}
      )

    failed = dump |> Dump.changeset(%{status: "failed"}) |> Nila.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    confirm_all_open_issues(view)

    assert has_element?(view, "#month-dump-#{failed.id}", "Extraction failed")

    assert has_element?(
             view,
             "#month-exit-gstr1",
             "Blocked · 1 sales packet remains unresolved"
           )

    assert has_element?(view, "#gstr1-filing-status", "Provisional")
    refute has_element?(view, "#gstr1-filing-status", "Ready for approval")
    refute has_element?(view, "#month-door-sign-r1")

    view |> element("#month-dump-abandon-#{failed.id}") |> render_click()

    assert render(view) =~ "Stopped waiting for that packet"
    refute has_element?(view, "#month-dump-abandon-#{failed.id}")

    assert has_element?(view, "#month-door-sign-r1")

    assert Nila.Repo.get!(Dump, failed.id).status == "discarded"
  end

  test "a member cannot stop waiting for a failed packet", %{org: org, client: client} do
    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{period: @period, kind: "sales", file_keys: ["dumps/unreadable.pdf"]}
      )

    failed = dump |> Dump.changeset(%{status: "failed"}) |> Nila.Repo.update!()

    member = user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, member.id, "member")
    member_conn = log_in_user(Phoenix.ConnTest.build_conn(), member)

    {:ok, view, _html} = live(member_conn, ~p"/gst/#{client.id}/#{@period}")

    # Abandoning unresolved intake is a senior-only audit decision. The control
    # is hidden, and the event is refused even when the client is driven directly.
    refute has_element?(view, "#month-dump-abandon-#{failed.id}")

    render_click(view, "abandon-dump", %{"dump-id" => failed.id})

    assert render(view) =~ "Only a senior can stop waiting for a packet."
    assert Nila.Repo.get!(Dump, failed.id).status == "failed"
  end

  test "downloads the portal-shaped GSTR-1 JSON", %{conn: conn, client: client} do
    conn = get(conn, ~p"/gstr1/#{client.id}/#{@period}/return.json")

    assert response_content_type(conn, :json)
    body = json_response(conn, 200)
    assert body["gstin"] == "33AEWPH4158J1Z3"
    assert body["fp"] == "102025"
    assert is_list(body["b2b"])
  end

  # Two lines of one bill fail the same check, so they are one issue against one
  # resolution target. `check_issues` is keyed per check and both checks resolve
  # to that issue, so a card per check put the same question on the page twice
  # under the same DOM id — `issue_dom_id/1` names the issue, and the issue is
  # one. Duplicate ids are invalid HTML and are what LiveView patches by.
  test "a merged line issue is one card, and every failing line still gets its ✗", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    period = "2025-11"

    # Lines 1 and 3 don't multiply out; line 2 does.
    invoices = [
      Gstr1.normalize_invoice(%{
        "data" => %{
          "invoice_number" => "41/2025-26",
          "invoice_date" => "04.11.2025",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "PONMANI AND CO", "gstin" => "33AAVCS8021P1ZB"},
          "line_items" => [
            arithmetic_line("Silver rod", 1000, 50),
            arithmetic_line("Silver wire", 500, 45),
            arithmetic_line("Silver sheet", 200, 10)
          ]
        }
      })
    ]

    failed = invoices |> hd() |> Gstr1.invoice_checks() |> Enum.reject(& &1["passed"])
    assert length(failed) == 2

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period))
      })

    assert {:error, {:live_redirect, %{to: review_path}}} =
             live(conn, ~p"/gst/#{client.id}/#{period}?invoice=41%2F2025-26")

    {:ok, view, _html} = live(conn, review_path)

    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#gstr1-checks [id^='gstr1-issue-']")
      |> LazyHTML.attribute("id")

    assert ids == ["gstr1-issue-line_arithmetic-line-1"]
    assert ids == Enum.uniq(ids)

    # The card names both lines, and line 3's own ✗ still states its arithmetic
    # — the question is asked once, nothing that failed goes unsaid.
    checks = view |> element("#gstr1-checks") |> render()
    assert checks =~ "line 1 tax 100"
    assert checks =~ "line 3 tax 20"
    assert checks =~ "L3: 200.00 × 18% = 20.00"
  end

  # The panel's HSN gate expands the workings rows for the code an issue carries
  # and unlocks the answer once they are all open. A merged issue therefore has
  # to carry every code it covers: holding only the first, reviewing 999999's
  # rows would clear an invoice whose 888888 rows were never rendered. Before
  # the collapse that took two separate reviews, and it still has to.
  test "a two-bad-code invoice cannot be covered by reviewing one of them" do
    alias Nila.Gst.Hsn.Validation, as: HsnValidation
    alias NilaWeb.Components.Gst.Month.Workings

    invoices = [
      %{
        "id" => "inv_01",
        "invoice_number" => "50/2025-26",
        "line_items" => [bad_hsn_line("Bogus", "999999"), bad_hsn_line("Also bogus", "888888")]
      }
    ]

    assert [issue] = HsnValidation.sales_issues(invoices)
    assert issue["hsn_codes"] == ["999999", "888888"]

    reviewed = MapSet.new(Workings.hsn_node_ids(invoices, "999999"))

    required =
      Enum.flat_map(issue["hsn_codes"], &Workings.hsn_node_ids(invoices, &1))

    assert reviewed != MapSet.new()
    assert required != []
    refute Enum.all?(required, &MapSet.member?(reviewed, &1))
  end

  defp arithmetic_line(description, taxable, half_tax) do
    %{
      "description" => description,
      "hsn_sac" => "7106",
      "taxable_value" => taxable,
      "cgst_rate" => 9,
      "cgst_amount" => half_tax,
      "sgst_rate" => 9,
      "sgst_amount" => half_tax
    }
  end

  defp bad_hsn_line(description, code) do
    %{
      "description" => description,
      "hsn_sac" => code,
      "hsn_validation" => %{"status" => "invalid", "code" => code},
      "taxable_value" => 1000,
      "cgst_rate" => 9,
      "cgst_amount" => 90,
      "sgst_rate" => 9,
      "sgst_amount" => 90
    }
  end

  test "another org cannot open the month or fetch the JSON", %{client: client} do
    %{user: other_user} = user_with_org_fixture()
    conn = log_in_user(build_conn(), other_user)

    assert {:error, {:live_redirect, %{to: "/today"}}} =
             live(conn, ~p"/gst/#{client.id}/#{@period}")

    conn =
      get(build_conn() |> log_in_user(other_user), ~p"/gstr1/#{client.id}/#{@period}/return.json")

    assert response(conn, 404)
  end
end
