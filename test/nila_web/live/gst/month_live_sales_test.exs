defmodule NilaWeb.Gst.MonthLiveSalesTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Purchase.Months, as: ClientMonths

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
    assert has_element?(view, "#month-door-sales-issues", "Check invoice 20/2025-26")
    assert render(view) =~ "to check"
  end

  test "the account states what came in and what it became", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    account = view |> element("#gstr1-account") |> render()

    assert account =~ "3 pages read"
    assert account =~ "3 invoices"
    assert account =~ "series 20/2025-26 – 22/2025-26, complete"
    assert account =~ "no duplicates"
    assert account =~ "86,752"
  end

  test "invoices triage into need-you and a collapsed verified count", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-invoices #gstr1-inv-20\\/2025-26")
    assert has_element?(view, "#gstr1-invoices-verified #gstr1-inv-21\\/2025-26")
    assert has_element?(view, "#gstr1-invoices-verified #gstr1-inv-22\\/2025-26")
    assert has_element?(view, "#gstr1-verified summary", "2 verified")
    refute view |> element("#gstr1-invoices-verified") |> render() =~ "clean"
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

    # The fold's summary line confesses the gap while the section is closed.
    assert has_element?(view, "#month-sales summary", "gap at 32/2025-26")

    # The account states it and anchors to the issue card that demands the
    # decision — same fact, two jobs.
    account = view |> element("#gstr1-account") |> render()
    assert account =~ "series 30/2025-26 – 33/2025-26"
    assert account =~ ~s(href="#gstr1-month-issue-sequence_gaps")
    assert has_element?(view, "#gstr1-month-issue-sequence_gaps")

    # No dump recorded a page count for this month, so the account says
    # nothing about pages rather than guessing.
    refute account =~ "read"
  end

  test "the verdict door opens the invoice carrying the issue", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute has_element?(view, "#gstr1-evidence-modal")

    view |> element("#month-door-sales-issues") |> render_click()

    assert has_element?(view, "#gstr1-evidence-modal")
    assert has_element?(view, "button[phx-value-target='20/2025-26:grand_total_mismatch']")
  end

  test "clicking an invoice shows its issues in the evidence modal", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    assert has_element?(view, "#gstr1-evidence-modal")
    assert has_element?(view, "#gstr1-evidence-modal p.line-clamp-2")
    assert render(view) =~ "Bill total doesn&#39;t tally"
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
    assert modal =~ "1,080.00 + 1,080.00"

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
    assert has_element?(
             view,
             "#gstr1-checks button[phx-value-target='20/2025-26:grand_total_mismatch']"
           )

    modal = view |> element("#gstr1-evidence-modal") |> render()
    assert length(String.split(modal, "Bill total doesn&#39;t tally")) == 2
  end

  test "opening an invoice marks its row read for the session", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert view |> element("#gstr1-inv-21\\/2025-26") |> render() =~ "font-medium"

    view |> element("#gstr1-inv-21\\/2025-26") |> render_click()
    view |> element("#gstr1-evidence-modal button[phx-click='close-evidence']") |> render_click()

    row = view |> element("#gstr1-inv-21\\/2025-26") |> render()
    refute row =~ "font-medium"
    assert row =~ "text-primary/60"
  end

  test "the workings body shows the derived return in working-sheet shape", %{
    conn: conn,
    client: client
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

    docs = view |> element("#gstr1-workings-docs") |> render()
    assert docs =~ "20/2025-26"
    assert docs =~ "22/2025-26"
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

  test "the return folds while issues are open, and a fold survives a re-render", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    # Issues are open, so the reader's job is the worklist: the return is one
    # tap away rather than four tables under it.
    refute has_element?(view, "#gstr1-return[open]")
    assert view |> element("#gstr1-return summary") |> render() =~ "The return"

    view |> element("#gstr1-return summary") |> render_click()
    assert has_element?(view, "#gstr1-return[open]")

    # A browser-toggled <details> would be reset by this patch.
    confirm_all_open_issues(view)
    assert has_element?(view, "#gstr1-return[open]")
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

  test "a signed month renders its workings from the snapshot", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#month-door-mark-reviewed") |> render_click()
    view |> element("#month-door-sign-r1") |> render_click()

    assert has_element?(view, "#gstr1-workings-b2b")
    assert view |> element("#gstr1-workings-b2b") |> render() =~ "PONMANI AND CO"
  end

  test "confirming an issue resolves it; undo reopens it", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    view
    |> element("button[phx-value-target='20/2025-26:grand_total_mismatch']", "Checked")
    |> render_click()

    assert render(view) =~ "Confirmed"

    view
    |> element("button[phx-value-target='20/2025-26:grand_total_mismatch']", "Undo")
    |> render_click()

    refute render(view) =~ "Confirmed"
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
    |> render_submit(%{"field" => "printed_grand_total", "value" => "76171.36"})

    refute render(view) =~ "Bill total doesn&#39;t tally"
  end

  test "the diff-vs-filed overlay lights differences, accepts them attributed, locks when signed",
       %{conn: conn, org: org, client: client, user: user} do
    alias Nila.Gst.Sales.Months, as: SalesMonths
    alias Nila.Gst.Sales.Resolutions, as: SalesResolutions

    # No filed return, no overlay — live months are untouched.
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    refute has_element?(view, "#gstr1-diff-summary")

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

    # Differences lit, agreements silent: one mismatch, one accept button.
    assert view |> element("#gstr1-diff-summary") |> render() =~ "1 differ"
    assert length(String.split(render(view), ~s(phx-click="accept_difference"))) == 2

    target = "invoice_item|33AABCP9487A1ZG|21/2025-26|18|txval"
    row = view |> element("button[phx-value-target='#{target}']") |> render()
    assert row =~ "Ours is right"

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

    # A signed month still shows the overlay — from the snapshot — but the
    # wall hides the verbs.
    confirm_all_open_issues(view)
    view |> element("#month-door-mark-reviewed") |> render_click()
    view |> element("#month-door-sign-r1") |> render_click()

    assert has_element?(view, "#gstr1-diff-summary")
    assert render(view) =~ "Accepted — ours is right"
    refute has_element?(view, "button[phx-click='accept_difference']")
    refute has_element?(view, "button[phx-click='undo'][phx-value-target='#{target}']")
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
    |> element("button[phx-value-field='line_items[0].taxable_value']", "Correct")
    |> render_click()

    view
    |> element("form[phx-submit='save_correct']")
    |> render_submit(%{"field" => "line_items[0].taxable_value", "value" => "1500"})

    # The nodes the re-derivation changed glow: party, rate bucket, HSN row,
    # and the month total in the account.
    assert view |> element("#gstr1-workings-party-33AABCP9487A1ZG") |> render() =~
             "workings-ripple"

    assert view |> element("#gstr1-workings-rate-18") |> render() =~ "workings-ripple"
    assert view |> element("#gstr1-workings-hsn-8415-18") |> render() =~ "workings-ripple"
    assert view |> element("#gstr1-account") |> render() =~ "workings-ripple"

    # The other party's numbers did not move, so its node stays quiet.
    refute view |> element("#gstr1-workings-party-33AAVCS8021P1ZM") |> render() =~
             "workings-ripple"

    refute view |> element("#gstr1-workings-hsn-2903-18") |> render() =~ "workings-ripple"

    # A resolution that changes no derived number clears the glow entirely.
    view
    |> element("button[phx-value-target='40/2025-26:cgst_sgst_unequal']")
    |> render_click()

    refute render(view) =~ "workings-ripple"
  end

  test "mark reviewed appears once issues are cleared and flips the state", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute has_element?(view, "#month-door-mark-reviewed")

    confirm_all_open_issues(view)

    assert has_element?(view, "#month-door-mark-reviewed")
    view |> element("#month-door-mark-reviewed") |> render_click()

    assert has_element?(view, "#gstr1-reviewed-badge")
    assert has_element?(view, "#month-door-sign-r1", "Sign the GSTR-1")
    assert render(view) =~ "Purchase bills not in"
  end

  defp confirm_all_open_issues(view) do
    # Month-level issues confirm from the strip; invoice issues from the modal.
    for invoice <- ["20/2025-26"] do
      view |> element("#gstr1-inv-#{String.replace(invoice, "/", "\\/")}") |> render_click()

      while_confirmable(view)

      view
      |> element("#gstr1-evidence-modal button[phx-click='close-evidence']")
      |> render_click()
    end

    while_confirmable(view)
  end

  defp while_confirmable(view) do
    if has_element?(view, "button[phx-click='confirm_issue']") do
      view |> element("button[phx-click='confirm_issue']:first-of-type") |> render_click()
      while_confirmable(view)
    end
  end

  test "owner signs a reviewed month; the wall blocks decisions; reopen lifts it", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#month-door-mark-reviewed") |> render_click()

    assert has_element?(view, "#month-door-sign-r1")
    view |> element("#month-door-sign-r1") |> render_click()

    assert has_element?(view, "#month-exit-gstr1")
    assert has_element?(view, "#month-door-file-sales[href='#month-exit-gstr1']")
    assert has_element?(view, "#gstr1-guide-download-json", "Download JSON")
    refute has_element?(view, "#gstr1-download-json")
    assert has_element?(view, "#month-exit-gstr1 a[target='_blank'][rel='noopener']")
    assert has_element?(view, "#gstr1-filed-arn")
    refute has_element?(view, "#month-door-sign-r1")
    refute has_element?(view, "button[phx-click='confirm_issue']")

    view |> element("#gstr1-reopen-signoff") |> render_click()

    refute has_element?(view, "#month-exit-gstr1", "signed off by")
    assert has_element?(view, "#month-door-sign-r1")
  end

  test "marking a signed GSTR-1 filed records the ARN and hides reopen", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#month-door-mark-reviewed") |> render_click()
    view |> element("#month-door-sign-r1") |> render_click()

    view
    |> element("#gstr1-mark-filed")
    |> render_submit(%{"arn" => "AA331025000001"})

    assert has_element?(view, "#gstr1-filed-note")
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
    view |> element("#month-door-mark-reviewed") |> render_click()

    refute has_element?(view, "#month-door-sign-r1")
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
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:done, client.id, @period}}
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
    view |> element("#month-door-mark-reviewed") |> render_click()
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

  test "downloads the portal-shaped GSTR-1 JSON", %{conn: conn, client: client} do
    conn = get(conn, ~p"/gstr1/#{client.id}/#{@period}/return.json")

    assert response_content_type(conn, :json)
    body = json_response(conn, 200)
    assert body["gstin"] == "33AEWPH4158J1Z3"
    assert body["fp"] == "102025"
    assert is_list(body["b2b"])
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
