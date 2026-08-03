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
    assert has_element?(view, "#month-verdict h1.text-h4", "Breeze Tech")
    assert has_element?(view, "#gstr1-verdict", "Blocked")
    assert has_element?(view, "#gstr1-verdict", "1 decision")
    assert has_element?(view, "#gstr1-review-required", "Take them one by one")
    assert has_element?(view, "#gstr1-required-clause", "1 decision")
    refute has_element?(view, "#month-door-sales-issues")
    assert has_element?(view, "#gstr1-inv-20\\/2025-26", "1 to answer")
    assert has_element?(view, "#month-sales-sources", "Sales bills")
    refute has_element?(view, "#month-exit-gstr1")
    refute has_element?(view, "#month-door-review-issue")
  end

  test "the control account ties source intake to the GSTR-1 draft", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    completeness = view |> element("#gstr1-completeness") |> render()

    assert completeness =~ "Source files received"
    assert completeness =~ "Invoice pages read"
    assert completeness =~ "Documents extracted"
    assert completeness =~ "Unique invoice numbers"
    assert has_element?(view, "#gstr1-reconciliation", "Taxable value")
    assert has_element?(view, "#gstr1-reconciliation", "Output tax")
    assert has_element?(view, "#gstr1-reconciliation", "₹0.00")
    assert has_element?(view, "#gstr1-verdict", "₹86,752.00")
    assert has_element?(view, "#gstr1-verdict", "₹15,615.36")
  end

  test "every invoice renders once in the visible register with its review state", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-register:not(details)")
    assert has_element?(view, "#gstr1-register table.text-ui")
    assert has_element?(view, "#gstr1-register thead.text-label")
    assert has_element?(view, "#gstr1-invoices #gstr1-inv-20\\/2025-26", "1 to answer")
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

    refute has_element?(view, "#month-sales summary")

    assert has_element?(view, "#gstr1-checks-before-filing", "Missing invoice numbers")
    assert has_element?(view, "#gstr1-checks-before-filing", "32/2025-26")
    assert has_element?(view, "#gstr1-completeness", "Sequence gaps")
    refute has_element?(view, "#gstr1-completeness", "Invoice pages read")
  end

  test "the unanswered cess question holds the month and offers two exits", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    month |> Ecto.Changeset.change(cess_evaluated: false) |> Nila.Repo.update!()
    confirm_sales_complete!(org, client, @period)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-checks-before-filing", "Cess has not been checked")
    assert has_element?(view, "#gstr1-completeness", "Not checked · awaiting your answer")
    assert has_element?(view, "#gstr1-cess-none")
    assert has_element?(view, "#gstr1-cess-applies")
    refute has_element?(view, "#month-door-sign-r1")
  end

  test "answering that no cess applies makes approval reachable", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    month |> Ecto.Changeset.change(cess_evaluated: false) |> Nila.Repo.update!()
    confirm_sales_complete!(org, client, @period)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    view |> element("#gstr1-cess-none") |> render_click()
    confirm_all_open_issues(view)

    assert has_element?(view, "#gstr1-completeness", "Checked · none found")
    assert has_element?(view, "#month-door-sign-r1")
  end

  test "answering that cess applies states the capability gap and blocks", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    month |> Ecto.Changeset.change(cess_evaluated: false) |> Nila.Repo.update!()
    confirm_sales_complete!(org, client, @period)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    view |> element("#gstr1-cess-applies") |> render_click()
    confirm_all_open_issues(view)

    assert has_element?(view, "#gstr1-checks-before-filing", "carries no cess")
    assert has_element?(view, "#gstr1-completeness", "Applies · this return cannot carry it")
    refute has_element?(view, "#gstr1-cess-none")
    refute has_element?(view, "#month-door-sign-r1")
  end

  test "a blocker nobody can answer is still named in the count that gates", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    # A credit note: the return has no cdnr table, so no reviewer action clears
    # it. It asks for no work, which is exactly why it used to fall out of a
    # count named after the work.
    invoices =
      Enum.map(month.invoices, fn
        %{"invoice_number" => "21/2025-26"} = invoice ->
          Map.put(invoice, "document", %{"credit_note" => true})

        invoice ->
          invoice
      end)

    month |> Ecto.Changeset.change(invoices: invoices) |> Nila.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-required-clause", "1 blocker")
    assert has_element?(view, "#gstr1-required-clause", "1 decision")
    assert has_element?(view, "#gstr1-verdict", "1 blocker")
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
          cess_evaluated: true,
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

    confirm_sales_complete!(org, client, "2025-12")
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/2025-12")

    assert has_element?(
             view,
             "#gstr1-advisory-hsn-new",
             "2 HSN/SAC codes are new for this client"
           )

    assert has_element?(view, "#gstr1-advisory-hsn-new", "28043000 · 29033990")
    assert has_element?(view, "#gstr1-advisory-hsn-rows", "Printed on the bill")

    # Context, not work: no confirm affordance, not in the gating clause, and
    # approval is reachable without anyone opening it.
    refute has_element?(view, "#gstr1-advisories button[phx-click='confirm_issue']")

    refute has_element?(view, "#gstr1-checks-before-filing")
    assert has_element?(view, "#gstr1-verdict", "Ready for approval")
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
        cess_evaluated: true,
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
    assert has_element?(view, "#gstr1-hsn-signoff", "checks before filing")
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
    assert has_element?(view, "#gstr1-completeness", "Duplicate documents excluded")
    assert has_element?(view, "#gstr1-completeness", "2")
    assert has_element?(view, "#gstr1-reconciliation", "Documents")
    assert has_element?(view, "#gstr1-reconciliation", "3")
    assert has_element?(view, "#gstr1-inv-#{copy_two["id"]}", "Duplicate copy")
    assert has_element?(view, "#gstr1-inv-#{copy_three["id"]}", "Duplicate copy")
  end

  test "the invoice row owns issue review without a detached next-issue action", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute has_element?(view, "#month-door-sales-issues")
    refute has_element?(view, "#month-door-review-issue")
    refute has_element?(view, "#gstr1-evidence-modal")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    assert_patch(view, ~p"/gst/#{client.id}/#{@period}?invoice=20%2F2025-26")
    assert has_element?(view, "#gstr1-evidence-modal")
    assert has_element?(view, "#gstr1-checks button", "File the extracted lines")

    assert has_element?(
             view,
             "#gstr1-rate-validation-scope",
             "imported taxable-goods rate candidates are checked independently"
           )
  end

  test "opening an invoice adds one history entry; navigating and closing add none", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    # Two flagged invoices, so previous/next actually have somewhere to go.
    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    invoices =
      Enum.map(month.invoices, fn
        %{"invoice_number" => "21/2025-26"} = invoice ->
          Map.put(invoice, "printed_grand_total", 1)

        invoice ->
          invoice
      end)

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, @period))
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    # Opening is a place the reader can Back out of, so it pushes.
    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()
    assert patch_kind(view) == :push

    # Walking the queue does not: twelve invoices would otherwise leave twelve
    # entries between the reader and the month he came from.
    view |> element("#gstr1-review-next") |> render_click()
    assert patch_kind(view) == :replace

    view |> element("#gstr1-review-previous") |> render_click()
    assert patch_kind(view) == :replace

    # Closing replaces too, so Back from the closed modal cannot reopen it.
    view
    |> element("#gstr1-evidence-modal button[phx-click='close-invoice-review']")
    |> render_click()

    assert patch_kind(view) == :replace
    refute has_element?(view, "#gstr1-evidence-modal")
  end

  # `assert_patch/1` reports the path but not whether it pushed or replaced, and
  # push-vs-replace is the whole question here. Reads the same proxy message
  # `assert_patch/1` consumes (`client_proxy.ex` `send_patch/3`), one field
  # further in — an undocumented shape, so a LiveView upgrade that restructures
  # it will fail here rather than silently pass.
  defp patch_kind(view) do
    %{proxy: {ref, topic, _}} = view
    assert_receive {^ref, {:patch, ^topic, %{kind: kind}}}
    kind
  end

  test "the invoice review URL survives refresh and close returns to the register", %{
    conn: conn,
    client: client
  } do
    review_path = ~p"/gst/#{client.id}/#{@period}?invoice=20%2F2025-26"
    {:ok, view, _html} = live(conn, review_path)

    assert has_element?(view, "#gstr1-evidence-modal")
    assert has_element?(view, "#gstr1-review-header", "1 to answer")
    assert has_element?(view, "#gstr1-review-header", "Filing blocked")

    assert has_element?(
             view,
             "#gstr1-review-previous[disabled]",
             "Previous flagged invoice"
           )

    assert has_element?(view, "#gstr1-review-next[disabled]", "Next flagged invoice")
    assert has_element?(view, "[data-review-target='gstr1-line-total']")
    assert has_element?(view, "[data-review-target='gstr1-line-total'] span", "1")

    view
    |> element("#gstr1-evidence-modal button[phx-click='close-invoice-review']")
    |> render_click()

    assert_patch(view, ~p"/gst/#{client.id}/#{@period}")
    refute has_element?(view, "#gstr1-evidence-modal")
    assert view |> element("#gstr1-inv-20\\/2025-26") |> render() =~ "bg-primary/[0.04]"
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

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}?invoice=20%2F2025-26")

    assert has_element?(
             view,
             "#gstr1-review-next[phx-value-inum='21/2025-26']:not([disabled])",
             "Next flagged invoice"
           )

    view |> element("#gstr1-review-next") |> render_click()

    assert_patch(view, ~p"/gst/#{client.id}/#{@period}?invoice=#{next_id}")
    assert has_element?(view, "#gstr1-evidence-modal-title", "21/2025-26")
    assert has_element?(view, "#gstr1-review-previous[phx-value-inum='20/2025-26']")
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

    {:ok, _month} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        issues: issues,
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period))
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}?invoice=44%2F2026-27")

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
    assert has_element?(view, "#gstr1-checks button", "File the extracted lines")

    modal = view |> element("#gstr1-evidence-modal") |> render()
    # One compact header shortcut and one issue card; the issue is not repeated
    # in a detached section below the checks.
    assert length(String.split(modal, "Bill total doesn&#39;t tally")) == 3
  end

  test "opening an invoice marks its row read for the session", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert view |> element("#gstr1-inv-21\\/2025-26") |> render() =~ "font-medium"

    view |> element("#gstr1-inv-21\\/2025-26") |> render_click()

    view
    |> element("#gstr1-evidence-modal button[phx-click='close-invoice-review']")
    |> render_click()

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

  test "the return workings remain visible while issues are open and after a re-render", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-return", "Return workings")
    assert has_element?(view, "#gstr1-workings-b2b")
    assert has_element?(view, "#gstr1-workings-rates")
    assert has_element?(view, "#gstr1-workings-hsn")
    assert has_element?(view, "#gstr1-workings-docs")

    confirm_all_open_issues(view)

    assert has_element?(view, "#gstr1-workings-hsn")
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
    org: org,
    client: client
  } do
    confirm_sales_complete!(org, client, @period)
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#month-door-sign-r1") |> render_click()

    assert has_element?(view, "#gstr1-workings-b2b")
    assert view |> element("#gstr1-workings-b2b") |> render() =~ "PONMANI AND CO"
  end

  test "a month signed before levels were mandatory renders as it did then", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Filing.Signoffs
    alias Nila.Gst.Sales.Months, as: SalesMonths

    confirm_sales_complete!(org, client, @period)
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
    assert has_element?(legacy_view, "#gstr1-verdict", "Approved")
    refute has_element?(legacy_view, "#gstr1-checks-before-filing")
    assert legacy_view |> element("#gstr1-workings-b2b") |> render() =~ "PONMANI AND CO"
  end

  test "confirming an issue resolves it; undo reopens it", %{
    conn: conn,
    client: client,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    view
    |> element("button[phx-click='resolve-invoice-issue']", "File the extracted lines")
    |> render_click()

    assert render(view) =~ "Resolved by #{user.name}"
    assert render(view) =~ "Accepted extracted line total"

    view
    |> element("#gstr1-checks button[phx-click='undo']", "Undo")
    |> render_click()

    refute render(view) =~ "Resolved by #{user.name}"
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

    confirm_sales_complete!(org, client, @period)

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

    # An approved month still shows the overlay — from the snapshot — but the
    # wall hides the verbs.
    confirm_all_open_issues(view)
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
    assert view |> element("#gstr1-verdict") |> render() =~ "workings-ripple"

    reconciliation = view |> element("#gstr1-completeness") |> render()
    assert reconciliation =~ "As printed"
    assert reconciliation =~ "Proposed after fixes"
    assert reconciliation =~ "₹3,000.00"
    assert reconciliation =~ "₹3,500.00"
    assert reconciliation =~ "Caused by invoice 40/2025-26"

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

  test "resolved checks make missing client confirmation actionable", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)

    assert has_element?(view, "#gstr1-invoices #gstr1-inv-20\\/2025-26", "Confirmed")
    refute has_element?(view, "#month-door-sign-r1")
    assert has_element?(view, "#gstr1-record-confirmation", "Record client confirmation")
    assert has_element?(view, "#gstr1-completeness", "Awaiting client confirmation")
  end

  test "a senior can override missing client confirmation only with a recorded reason", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#gstr1-record-confirmation") |> render_click()

    view
    |> element("#gstr1-completeness-override-form")
    |> render_submit(%{"override" => %{"reason" => ""}})

    assert has_element?(view, "#gstr1-completeness-override-form .text-error")

    view
    |> element("#gstr1-completeness-override-form")
    |> render_submit(%{
      "override" => %{"reason" => "Client confirmed the final register by phone"}
    })

    assert has_element?(view, "#gstr1-completeness", "Overridden by")
    assert has_element?(view, "#month-door-sign-r1")
  end

  test "client confirmation action queues a period-specific WhatsApp request", %{
    conn: conn,
    client: client
  } do
    {:ok, client} =
      Clients.update_client(client, %{
        phone: "9876543210",
        chase_channel: "whatsapp"
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    confirm_all_open_issues(view)

    view |> element("#gstr1-record-confirmation") |> render_click()
    assert has_element?(view, "#gstr1-send-completeness-request")
    view |> element("#gstr1-send-completeness-request") |> render_click()

    assert_enqueued(
      worker: Nila.Gst.Chase.CompletenessSender,
      args: %{"client_id" => client.id, "period" => @period}
    )

    assert render(view) =~ "WhatsApp confirmation request queued"
  end

  defp confirm_all_open_issues(view) do
    # Month-level issues confirm from the strip; invoice issues from the modal.
    for invoice <- ["20/2025-26"] do
      view |> element("#gstr1-inv-#{String.replace(invoice, "/", "\\/")}") |> render_click()

      while_confirmable(view)

      view
      |> element("#gstr1-evidence-modal button[phx-click='close-invoice-review']")
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
    org: org,
    client: client
  } do
    confirm_sales_complete!(org, client, @period)
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)

    assert has_element?(view, "#month-door-sign-r1", "Approve GSTR-1")
    view |> element("#month-door-sign-r1") |> render_click()

    assert has_element?(view, "#month-exit-gstr1")
    assert has_element?(view, "#gstr1-invoices #gstr1-inv-20\\/2025-26")
    assert has_element?(view, "#gstr1-workings-b2b")
    assert has_element?(view, "#month-door-file-sales[href='#month-exit-gstr1']")
    assert has_element?(view, "#gstr1-guide-download-json", "Download GST JSON")
    assert has_element?(view, "#month-exit-gstr1", "Approved by")
    assert has_element?(view, "#month-exit-gstr1", "Draft version")
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
    org: org,
    client: client
  } do
    confirm_sales_complete!(org, client, @period)
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#month-door-sign-r1") |> render_click()

    view
    |> element("#gstr1-mark-filed")
    |> render_submit(%{"arn" => "AA331025000001"})

    assert has_element?(view, "#gstr1-filed-note")
    assert has_element?(view, "#gstr1-invoices #gstr1-inv-20\\/2025-26")
    assert has_element?(view, "#gstr1-workings-b2b")
    assert render(view) =~ "AA331025000001"
    refute has_element?(view, "#gstr1-mark-filed")
    refute has_element?(view, "#gstr1-reopen-signoff")
  end

  test "a member cannot see the sign-off button", %{org: org, client: client} do
    confirm_sales_complete!(org, client, @period)
    member = Nila.AccountsFixtures.user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, member.id, "member")
    conn = log_in_user(build_conn(), member)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)

    refute has_element?(view, "#month-door-sign-r1")
    assert has_element?(view, "#month-exit-gstr1", "Ready for a senior to approve")
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
    confirm_sales_complete!(org, client, @period)
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
