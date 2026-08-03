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

    # Required, but nothing here is blocking — the badge counts the work rather
    # than spending the strongest word it has on a month a reviewer can finish
    # on this screen. See the blocked/non-blocked pair below.
    assert has_element?(view, "#gstr1-verdict", "to answer")
    refute has_element?(view, "#gstr1-verdict", "Blocked")
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

    assert has_element?(
             view,
             "#gstr1-checks-before-filing",
             "Both IGST and CGST/SGST on one bill"
           )

    assert has_element?(view, "#gstr1-required-clause", "1 decision")
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

    # Before the answer, every open issue is one somebody can settle here, so
    # the badge counts the work. "Blocked" is the strongest word it has, and
    # spending it on an ordinary month leaves nothing louder for this one.
    assert has_element?(view, "#gstr1-verdict", "to answer")
    refute has_element?(view, "#gstr1-verdict", "Blocked")

    view |> element("#gstr1-cess-applies") |> render_click()
    confirm_all_open_issues(view)

    assert has_element?(view, "#gstr1-checks-before-filing", "carries no cess")
    assert has_element?(view, "#gstr1-completeness", "Applies · this return cannot carry it")
    refute has_element?(view, "#gstr1-cess-none")
    refute has_element?(view, "#month-door-sign-r1")

    # Now nothing on this page moves the month, and the badge says so.
    assert has_element?(view, "#gstr1-verdict", "Blocked")
    refute has_element?(view, "#gstr1-verdict", "to answer")
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

  test "the month shows the object being approved, and claims nothing it cannot check", %{
    conn: conn,
    org: org,
    client: client
  } do
    confirm_sales_complete!(org, client, @period)
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-filing-summary", "What this return files")
    assert has_element?(view, "#gstr1-filing-b2b", "B2B regular")

    # One row, because `derive/2` builds b2b, hsn and doc_issue and nothing
    # else. Printing "Credit notes: none" here would be an assertion nobody has
    # made and the engine cannot check.
    assert has_element?(view, "#gstr1-filing-capability", "stops the month")
    refute has_element?(view, "#gstr1-filing-confirmed-absent")

    # It reports the work standing against the filing, not a bare "blocked".
    assert has_element?(view, "#gstr1-filing-b2b", "1 decision")

    # Only once a human has actually answered does the page say what is absent.
    confirm_all_open_issues(view)

    assert has_element?(view, "#gstr1-filing-confirmed-absent", "Confirmed absent this month")
    assert has_element?(view, "#gstr1-filing-b2b", "Ready")
  end

  describe "what the pile cannot say about itself" do
    test "a month is not approvable until somebody answers for its completeness", %{
      conn: conn,
      org: org,
      client: client
    } do
      confirm_sales_complete!(org, client, @period)
      {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

      # Files, pages and sequence gaps are internal consistency. One perfectly
      # read file can still be half a month.
      assert has_element?(view, "#gstr1-completeness-attestation", "6 unanswered")

      assert has_element?(
               view,
               "#gstr1-attest-credit_or_debit_notes",
               "Were any credit or debit notes issued"
             )

      # Exports, SEZ and B2C are asked apart, because each yes routes to a
      # different capability gap.
      assert has_element?(view, "#gstr1-attest-exports")
      assert has_element?(view, "#gstr1-attest-sez_supplies")
      assert has_element?(view, "#gstr1-attest-b2c_supplies")
      assert has_element?(view, "#gstr1-attest-cancelled_documents")
      assert has_element?(view, "#gstr1-attest-additional_series")
    end

    test "'yes' names the next move rather than only refusing", %{
      conn: conn,
      org: org,
      client: client
    } do
      confirm_sales_complete!(org, client, @period)
      {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

      view
      |> element("#gstr1-attest-credit_or_debit_notes button[phx-value-answer='yes']")
      |> render_click()

      # A blocker that only says "Nila cannot do this" is honest and
      # operationally useless — the cess lesson.
      assert has_element?(view, "#gstr1-attest-credit_or_debit_notes", "see the blocker below")
      assert has_element?(view, "#gstr1-checks-before-filing", "no cdnr table")
      assert has_element?(view, "#gstr1-checks-before-filing", "filed manually")
      refute has_element?(view, "#month-door-sign-r1")
    end

    test "'don't know' is a real answer that withholds approval", %{
      conn: conn,
      org: org,
      client: client
    } do
      confirm_sales_complete!(org, client, @period)
      {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

      confirm_all_open_issues_except_completeness(view)

      # Nobody is forced to assert "no" to proceed: this reviewer genuinely does
      # not know about exports and says so, then settles everything else.
      view
      |> element("#gstr1-attest-exports button[phx-value-answer='unknown']")
      |> render_click()

      answer_completeness(view, "no")

      assert has_element?(view, "#gstr1-attest-exports", "Asked the client")
      refute has_element?(view, "#month-door-sign-r1")

      # And it is reversible: answering it settles the month.
      view |> element("#gstr1-attest-exports button[phx-click='undo']") |> render_click()
      view |> element("#gstr1-attest-exports button[phx-value-answer='no']") |> render_click()

      assert has_element?(view, "#month-door-sign-r1")
    end

    test "a later pile reopens an answer given about a smaller one", %{
      conn: conn,
      org: org,
      client: client
    } do
      alias Nila.Gst.Sales.Months, as: SalesMonths

      confirm_sales_complete!(org, client, @period)
      {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

      answer_completeness(view)
      refute has_element?(view, "#gstr1-attest-exports button[phx-value-answer='no']")

      # More bills arrive. An answer about one set of invoices cannot speak for
      # a set that has grown.
      {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

      wider =
        month.invoices ++
          [
            Nila.Gst.Sales.Gstr1.normalize_invoice(%{
              "data" => %{
                "invoice_number" => "99/2025-26",
                "invoice_date" => "04.10.2025",
                "seller" => %{"gstin" => client.gstin},
                "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
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
          ]

      {:ok, _} =
        SalesMonths.upsert(%{
          org_id: org.id,
          client_id: client.id,
          period: @period,
          invoices: wider,
          issues: Nila.Gst.Sales.Gstr1.validation_issues(wider)
        })

      {:ok, reopened, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

      assert has_element?(reopened, "#gstr1-completeness-attestation", "6 unanswered")
    end
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

    # The completeness questions do gate — nothing is wrong with these bills,
    # but nobody has yet said whether they are the whole month.
    answer_completeness(view)

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
    assert_patch(view, ~p"/gst/#{client.id}/#{@period}")
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
    assert frozen["effect"]["tax"]
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
    assert has_element?(view, "#gstr1-register th", "Tax · sum of extracted lines")
    assert has_element?(view, "#gstr1-register-basis", "per-rate recomputation")
    assert has_element?(view, "#gstr1-workings-basis", "what this return files")
    assert has_element?(view, "#gstr1-workings-b2b th", "Proposed GSTR-1")
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
    |> render_submit(%{
      "correction" => %{"field" => "line_items[0].taxable_value", "value" => "1500"}
    })

    _ = :sys.get_state(view.pid)

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
    # Month-level issues stay on the working paper; invoice issues live in SalesLive.
    for invoice <- ["20/2025-26"] do
      view |> element("#gstr1-inv-#{String.replace(invoice, "/", "\\/")}") |> render_click()

      while_confirmable(view)

      view
      |> element("#sales-review button[phx-click='done']")
      |> render_click()
    end

    while_confirmable(view)
    answer_completeness(view)
  end

  defp confirm_all_open_issues_except_completeness(view) do
    for invoice <- ["20/2025-26"] do
      view |> element("#gstr1-inv-#{String.replace(invoice, "/", "\\/")}") |> render_click()

      while_confirmable(view)

      view
      |> element("#sales-review button[phx-click='done']")
      |> render_click()
    end

    while_confirmable(view)
  end

  # The questions the pile cannot answer about itself. A month is not approvable
  # until somebody says whether there were credit notes, exports, SEZ or B2C
  # supplies, cancellations or a second series — so a test driving a month to
  # approval has to answer them the way a reviewer would.
  defp answer_completeness(view, answer \\ "no") do
    for q <- Nila.Gst.Sales.Workings.completeness_questions() do
      selector =
        "#gstr1-attest-#{q.key} button[phx-click='attest-completeness'][phx-value-answer='#{answer}']"

      if has_element?(view, selector), do: view |> element(selector) |> render_click()
    end
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
