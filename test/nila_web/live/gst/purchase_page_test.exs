defmodule NilaWeb.Gst.PurchasePageTest do
  use NilaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Nila.GstFixtures
  alias Nila.Gst.Purchase.{Months, Reconciliation, Register}

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Purchase QA",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    %{conn: log_in_user(conn, user), org: org, user: user, client: client}
  end

  test "empty month provides separate purchase and portal input paths", c do
    {:ok, view, _} = live(c.conn, path(c))
    assert has_element?(view, "#purchases-page")
    assert has_element?(view, "#purchase-empty", "Import the purchase register")
    assert has_element?(view, "#purchase-input-status", "Purchases: not imported")
    assert has_element?(view, "#purchase-fetch-2b[href*='client_id=#{c.client.id}']")
    refute has_element?(view, "#purchase-workings-download")
    view |> element("#purchase-import-excel") |> render_click()
    assert_redirect(view, path(c) <> "/import-excel")
  end

  test "mismatches remain visible and search/filter survive opening review", c do
    book = invoice("BOOK-1", "INV-1", 90_000)
    portal = invoice(nil, "INV-1", 95_000)
    matched = invoice("BOOK-2", "INV-2", 90_000)
    seed(c, [book, matched], [portal, Map.delete(matched, "id")])
    {:ok, view, _} = live(c.conn, path(c))

    assert has_element?(view, "#purchase-result-count", "1 review item"),
           render(element(view, "#purchase-result-count"))

    assert has_element?(view, "#purchase-items", "INV-1")
    refute has_element?(view, "#purchase-items", "INV-2")
    view |> element("#purchase-filter-mismatch") |> render_click()
    assert_patch(view, path(c) <> "?filter=mismatch&q=")
    view |> form("#purchase-search", search: %{q: "INV-1"}) |> render_change()
    assert_patch(view, path(c) <> "?filter=mismatch&q=INV-1")
    assert has_element?(view, "#purchase-items a[href*='filter=mismatch'][href*='q=INV-1']")
    assert has_element?(view, "#purchase-workings-download")
  end

  test "2B-only month does not claim purchase books are available", c do
    seed(c, [], [invoice(nil, "PORTAL-1", 90_000)])
    {:ok, view, _} = live(c.conn, path(c))
    assert has_element?(view, "#purchase-input-status", "Purchases: not imported")
    assert has_element?(view, "#purchase-items", "PORTAL-1")
    assert has_element?(view, "#purchase-next-step", "Select invoices to exclude from ITC")
    assert has_element?(view, "#purchase-search")
    refute has_element?(view, "#purchase-filters")
    refute has_element?(view, "#purchase-result-count")
  end

  test "bulk ITC exclusion works before books and keeps other invoices undecided", c do
    portal = [
      invoice(nil, "DRY-1", 9000),
      invoice(nil, "CITY-1", 18000),
      invoice(nil, "OTHER-1", 4500)
    ]

    seed(c, [], portal)
    {:ok, view, _} = live(c.conn, path(c))

    {:ok, data} =
      NilaWeb.Gst.PurchaseWorkspace.load(
        Nila.Accounts.Scope.for_user(c.user),
        c.client.id,
        "2026-08"
      )

    dry = Enum.find(data.items, &(&1.invoice_number == "DRY-1"))
    city = Enum.find(data.items, &(&1.invoice_number == "CITY-1"))
    other = Enum.find(data.items, &(&1.invoice_number == "OTHER-1"))
    view |> element("#purchase-select-#{dry.id}") |> render_click()
    view |> form("#purchase-search", search: %{q: "CITY-1"}) |> render_change()
    view |> element("#purchase-select-#{city.id}") |> render_click()
    assert has_element?(view, "#purchase-selection", "2 selected")
    assert has_element?(view, "#purchase-selection-count", "1 outside this filter")
    assert has_element?(view, "#purchase-search")
    view |> element("#purchase-exclude-itc") |> render_click()
    assert has_element?(view, "#purchase-claim-dialog[role=dialog]")
    assert has_element?(view, "#purchase-selected-invoices", "DRY-1")
    view |> element("#purchase-cancel-claim") |> render_click()
    refute has_element?(view, "#purchase-claim-dialog")
    assert has_element?(view, "#purchase-selection", "2 selected")
    view |> element("#purchase-exclude-itc") |> render_click()
    view |> form("#purchase-claim-form", claim: %{reason: "Personal expenses"}) |> render_submit()
    refute has_element?(view, "#purchase-selection")
    view |> form("#purchase-search", search: %{q: ""}) |> render_change()
    assert has_element?(view, "#purchase-claim-state-#{dry.id}", "Not claiming")
    assert has_element?(view, "#purchase-claim-state-#{city.id}", "Not claiming")
    refute has_element?(view, "#purchase-claim-state-#{other.id}")
    assert has_element?(view, "#purchase-items", "Personal expenses")

    {:ok, refreshed, _} = live(c.conn, path(c))
    assert has_element?(refreshed, "#purchase-claim-state-#{dry.id}", "Not claiming")
    refreshed |> element("#purchase-select-#{dry.id}") |> render_click()
    refreshed |> element("#purchase-reopen-itc") |> render_click()
    refute has_element?(refreshed, "#purchase-claim-state-#{dry.id}")
    assert has_element?(refreshed, "#purchase-claim-state-#{city.id}")
  end

  test "a saved statement needs one reconciliation action, not repeated imports", c do
    statement =
      Nila.Repo.insert!(%Nila.Gst.Portal.Statement{
        client_id: c.client.id,
        gstin: c.client.gstin,
        period: "2026-08",
        status: "ready",
        fetched_at: DateTime.utc_now(),
        document: %{
          "data" => %{
            "gstin" => c.client.gstin,
            "rtnprd" => "082026",
            "docdata" => %{"b2b" => []}
          }
        }
      })

    {:ok, view, _} = live(c.conn, path(c))
    assert has_element?(view, "#purchase-use-2b", "Start reconciliation")
    view |> element("#purchase-use-2b") |> render_click()
    refute has_element?(view, "#purchase-use-2b")
    assert has_element?(view, "#purchase-processing")
    # A refresh of identical portal content must not add another manual step.
    statement
    |> Ecto.Changeset.change(fetched_at: DateTime.add(statement.fetched_at, 60))
    |> Nila.Repo.update!()

    send(view.pid, {:gst_statement_fetched, statement.id})
    refute has_element?(view, "#purchase-use-2b")
  end

  test "matched invoices with supplier identity findings remain in review", c do
    book = invoice("OWN-GSTIN", "OWN-1", 90_000) |> Map.put("vendor_gstin", c.client.gstin)
    seed(c, [book], [Map.delete(book, "id")])
    {:ok, view, _} = live(c.conn, path(c))
    assert has_element?(view, "#purchase-items", "OWN-1")
    assert has_element?(view, "#purchase-items", "Matched · needs review")

    {:ok, workspace} =
      NilaWeb.Gst.PurchaseWorkspace.load(
        Nila.Accounts.Scope.for_user(c.user),
        c.client.id,
        "2026-08"
      )

    item = Enum.find(workspace.items, &(&1.kind == :books))
    assert item.flagged?
    assert Enum.any?(item.flags, &(&1["code"] == "own_gstin_as_vendor"))

    {:ok, detail, _} =
      live(
        c.conn,
        NilaWeb.Gst.PurchaseWorkspace.review_path(
          c.client.id,
          "2026-08",
          item.id,
          "needs_review",
          ""
        )
      )

    assert has_element?(detail, "#purchase-review-checks")
  end

  test "another firm's client cannot be opened", c do
    %{org: other} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{org_id: other.id, name: "Other firm", type: "company"})

    assert {:error, {:live_redirect, %{to: "/clients"}}} =
             live(c.conn, "/gst/#{client.id}/2026-08/purchases")
  end

  defp path(c), do: "/gst/#{c.client.id}/2026-08/purchases"

  test "blocked upload can be kept with an audited reason and processed", c do
    dump = questioned(c, "purchase", "period_mismatch")
    {:ok, view, _} = live(c.conn, path(c))
    assert has_element?(view, "#purchase-intake-#{dump.id}", "outside this month")
    view |> element("#purchase-intake-#{dump.id}-keep") |> render_click()

    view
    |> form("#purchase-intake-form-#{dump.id}",
      intake: %{reason: "Late receipt; review in August"}
    )
    |> render_submit()

    assert {:ok, kept} = Nila.Gst.Intake.Dumps.fetch(c.org.id, dump.id)
    assert kept.status == "extracted"

    assert Nila.Gst.Intake.Dumps.precondition_answer(kept)["reason"] ==
             "Late receipt; review in August"

    assert :ok =
             Nila.Gst.Intake.DumpWorker.perform(%Oban.Job{
               args: %{"dump_id" => dump.id},
               attempt: 1
             })

    assert {:ok, _} = Months.get_by_period(c.org.id, c.client.id, "2026-08")
  end

  test "zero-overlap statement can be explicitly left out without losing its audit", c do
    dump = questioned(c, "gstr2b", "zero_overlap")
    {:ok, view, _} = live(c.conn, path(c))

    assert has_element?(
             view,
             "#purchase-intake-#{dump.id}",
             "None of the purchase records matched"
           )

    view |> element("#purchase-intake-#{dump.id}-discard") |> render_click()
    view |> form("#purchase-intake-form-#{dump.id}") |> render_submit()
    assert {:ok, discarded} = Nila.Gst.Intake.Dumps.fetch(c.org.id, dump.id)
    assert discarded.status == "discarded"
    assert Nila.Gst.Intake.Dumps.precondition_answer(discarded)["answered_by_id"] == c.user.id
    refute has_element?(view, "#purchase-intake-#{dump.id}")
  end

  test "move opens the new dedicated purchase page", c do
    dump = questioned(c, "purchase", "period_mismatch")
    {:ok, view, _} = live(c.conn, path(c))
    view |> element("#purchase-intake-#{dump.id}-move") |> render_click()

    view
    |> form("#purchase-intake-form-#{dump.id}", intake: %{period: "2026-07"})
    |> render_submit()

    assert_redirect(view, "/gst/#{c.client.id}/2026-07/purchases?filter=needs_review&q=")
    assert {:ok, moved} = Nila.Gst.Intake.Dumps.fetch(c.org.id, dump.id)
    assert moved.period == "2026-07"
  end

  test "GSTR-2B cannot be moved to another return month, even by a forged event", c do
    dump = questioned(c, "gstr2b", "zero_overlap")
    {:ok, view, _} = live(c.conn, path(c))
    refute has_element?(view, "#purchase-intake-#{dump.id}-move")

    render_submit(view, "intake-answer", %{
      "intake" => %{
        "id" => to_string(dump.id),
        "answer" => "move",
        "period" => "2026-07"
      }
    })

    assert {:ok, unchanged} = Nila.Gst.Intake.Dumps.fetch(c.org.id, dump.id)
    assert unchanged.period == "2026-08"
    assert unchanged.status == "needs_confirmation"
    assert has_element?(view, "#purchase-error", "cannot be moved")
  end

  test "forged confirmation cannot change another client's upload or a newly frozen month", c do
    {:ok, other} = Nila.Clients.create_client(%{org_id: c.org.id, name: "Other", type: "company"})
    other_dump = questioned(%{c | client: other}, "purchase", "period_mismatch")
    dump = questioned(c, "purchase", "period_mismatch")
    {:ok, view, _} = live(c.conn, path(c))

    render_submit(view, "intake-answer", %{
      "intake" => %{"id" => to_string(other_dump.id), "answer" => "discard"}
    })

    assert {:ok, %{status: "needs_confirmation"}} =
             Nila.Gst.Intake.Dumps.fetch(c.org.id, other_dump.id)

    Nila.Repo.insert!(%Nila.Gst.Purchase.Month{
      org_id: c.org.id,
      client_id: c.client.id,
      period: "2026-08",
      state: "filed",
      filed_at: DateTime.utc_now()
    })

    render_submit(view, "intake-answer", %{
      "intake" => %{"id" => to_string(dump.id), "answer" => "discard"}
    })

    assert {:ok, %{status: "needs_confirmation"}} = Nila.Gst.Intake.Dumps.fetch(c.org.id, dump.id)
    assert has_element?(view, "#purchase-error", "signed off or filed")
  end

  test "held and after-filing uploads explain why they are excluded", c do
    held = questioned(c, "purchase", "period_mismatch") |> Nila.Gst.Intake.Dumps.mark_held()
    filed = questioned(c, "gstr2b", "zero_overlap") |> Nila.Gst.Intake.Dumps.mark_after_filing()
    {:ok, view, _} = live(c.conn, path(c))
    assert has_element?(view, "#purchase-intake-#{held.id}", "Waiting for a senior")
    assert has_element?(view, "#purchase-intake-#{filed.id}", "Arrived after filing")
  end

  test "viewer cannot confirm intake even through a forged event", c do
    dump = questioned(c, "purchase", "period_mismatch")
    scope = Nila.Accounts.Scope.for_user(c.user)
    scope.membership |> Ecto.Changeset.change(role: "viewer") |> Nila.Repo.update!()
    {:ok, view, _} = live(c.conn, path(c))
    assert has_element?(view, "#purchase-intake-#{dump.id}-keep[disabled]")

    render_submit(view, "intake-answer", %{
      "intake" => %{"id" => to_string(dump.id), "answer" => "discard"}
    })

    assert {:ok, %{status: "needs_confirmation"}} = Nila.Gst.Intake.Dumps.fetch(c.org.id, dump.id)
  end

  defp questioned(c, kind, issue) do
    {:ok, dump} =
      Nila.Gst.Intake.Dumps.record(
        %{org_id: c.org.id, client_id: c.client.id, brought_in_by_id: c.user.id},
        %{
          period: "2026-08",
          kind: kind,
          invoices: [invoice("intake-1", "INV-LATE", 90_000)],
          meta: %{"original_name" => "purchase.xlsx"}
        }
      )

    Nila.Gst.Intake.Dumps.mark_needs_confirmation(dump, %{
      "kind" => issue,
      "kinds" => [issue],
      "modal_period" => "2026-07"
    })
  end

  defp invoice(id, number, tax) do
    %{
      "id" => id,
      "vendor_name" => "Sharma Steels",
      "vendor_gstin" => "33AALCP2218B1ZX",
      "invoice_number" => number,
      "invoice_date" => "2026-08-05",
      "taxable_paise" => 1_000_000,
      "tax_paise" => %{"cgst" => tax, "sgst" => tax, "igst" => 0},
      "total_paise" => 1_000_000 + tax * 2,
      "images" => []
    }
  end

  defp seed(c, books, portal) do
    gstr2b_arrived!(c.org, c.client, "2026-08", portal)
    recon = Reconciliation.reconcile(books, portal)
    rows = Register.rows(books, recon, %{})

    {:ok, month} =
      Months.upsert(%{
        org_id: c.org.id,
        client_id: c.client.id,
        period: "2026-08",
        state: "worked",
        recon: recon,
        register_rows: rows,
        summary: Register.summary(rows)
      })

    month
  end
end
