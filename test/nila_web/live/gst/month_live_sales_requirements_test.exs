defmodule NilaWeb.Gst.MonthLiveSalesRequirementsTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures
  import NilaWeb.Gst.MonthLiveSalesHelpers, only: [confirm_all_open_issues: 1]

  alias Nila.Clients

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
            %{"printed_taxable_value" => 5000, "igst_rate" => 18, "igst_amount" => 900},
            %{
              "printed_taxable_value" => 5000,
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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{period}?track=sales")

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
                "printed_taxable_value" => 1000,
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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{period}?track=sales")

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
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

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

    # An amendment still has no supported derivation, so no reviewer action clears
    # it. It asks for no work, which is exactly why blockers must remain in the
    # count even when the review queue has no answer.
    invoices =
      Enum.map(month.invoices, fn
        %{"invoice_number" => "21/2025-26"} = invoice ->
          Map.put(invoice, "document_status", "amendment")

        invoice ->
          invoice
      end)

    month |> Ecto.Changeset.change(invoices: invoices) |> Nila.Repo.update!()

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

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
              "printed_taxable_value" => 1_000,
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
      |> Map.put("document_status", "amendment")

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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{period}?track=sales")

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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

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
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

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

  test "an interstate unregistered note requires its original sale category", %{
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
          |> Map.update("bill_to", %{}, &Map.put(&1 || %{}, "gstin", nil))
          |> Map.put("recipient_registration", "unregistered")
          |> Map.put("place_of_supply", "29")
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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    assert Enum.any?(
             Gstr1.blocking_issues(invoices),
             &(&1["code"] == "missing_original_sale_category")
           )

    assert has_element?(view, "#gstr1-checks-before-filing", "21/2025-26")

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
              "printed_taxable_value" => 10_000,
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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/2025-12?track=sales")

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
                "printed_taxable_value" => 10_000,
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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{period}?track=sales")

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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

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
end
