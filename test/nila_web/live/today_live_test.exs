defmodule NilaWeb.TodayLiveTest do
  use NilaWeb.ConnCase
  use Oban.Testing, repo: Nila.Repo

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.{Arrival, Arrivals, Chase, ClientMonths, Dumps, DumpWorker, SalesMonths}

  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  defp recon_with_2b_gap do
    %{
      "matched" => [],
      "value_mismatch" => [],
      "needs_human" => [],
      "in_books_not_2b" => [],
      "in_2b_not_books" => [
        %{
          "gstr2b" => %{
            "vendor_name" => "Sharma Steels",
            "vendor_gstin" => "33AAACS1234A1Z9",
            "invoice_number" => "INV-042",
            "invoice_date" => "2025-10-12",
            "taxable_paise" => 1_000_000,
            "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
            "total_paise" => 1_180_000
          }
        }
      ]
    }
  end

  defp seed_client_month(org, client, recon) do
    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        recon: recon,
        summary: %{"buckets" => %{"matched" => 0, "in_2b_not_books" => 1}}
      })

    month
  end

  test "pending arrivals render, prefill, and route through the existing dump worker", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    {:ok, arrival} =
      Arrivals.ingest(
        %{org_id: org.id, client_id: client.id},
        %{
          source: "whatsapp",
          sender: "919876543210",
          filename: "purchase.pdf",
          content_type: "application/pdf",
          bytes: "%PDF-1.4 fake"
        }
      )

    {:ok, view, _html} = live(conn, ~p"/today")
    assert has_element?(view, "#pending-arrivals", "Breeze Tech sent a file over WhatsApp")

    view |> element("#arrival-group-#{arrival.id}") |> render_click()
    assert has_element?(view, "#arrival-sort-modal")
    assert has_element?(view, "#arrival-sort-form option[selected][value='#{client.id}']")

    period = Nila.Gst.Calendar.closeable_period(Date.utc_today())
    assert has_element?(view, "#arrival-sort-form input[value='#{period}']")

    view
    |> form("#arrival-sort-form",
      arrival: %{client_id: client.id, period: period, kind: "purchase"}
    )
    |> render_submit()

    refute has_element?(view, "#arrival-sort-modal")
    refute has_element?(view, "#pending-arrivals")

    routed = Nila.Repo.get!(Arrival, arrival.id)
    assert routed.status == "routed"
    assert routed.routed_dump_id
    assert_enqueued(worker: DumpWorker, args: %{dump_id: routed.routed_dump_id})
    assert Nila.Repo.get!(Nila.Gst.Dump, routed.routed_dump_id).brought_in_by_id == user.id
  end

  test "an unknown WhatsApp number stays unattributed for sorting", %{conn: conn, org: org} do
    {:ok, arrival} =
      Arrivals.ingest(
        %{org_id: org.id, client_id: nil},
        %{
          source: "whatsapp",
          sender: "919999999999",
          filename: "mystery.pdf",
          content_type: "application/pdf",
          bytes: "%PDF-1.4 fake"
        }
      )

    {:ok, view, _html} = live(conn, ~p"/today")
    assert has_element?(view, "#arrival-group-#{arrival.id}", "Unknown number +919999999999")

    view |> element("#arrival-group-#{arrival.id}") |> render_click()
    refute has_element?(view, "#arrival-sort-form option[selected][value]")
  end

  test "a modal closes honestly when another operator sorts its arrival", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, arrival} =
      Arrivals.ingest(
        %{org_id: org.id, client_id: client.id},
        %{
          source: "email",
          sender: "accounts@breeze.example",
          filename: "purchase.pdf",
          content_type: "application/pdf",
          bytes: "%PDF-1.4 fake"
        }
      )

    {:ok, view, _html} = live(conn, ~p"/today")
    view |> element("#arrival-group-#{arrival.id}") |> render_click()
    assert has_element?(view, "#arrival-sort-modal")

    assert {:ok, _} = Arrivals.dismiss_many([arrival])

    assert render(view) =~ "These files were already sorted — refreshed."
    refute has_element?(view, "#arrival-sort-modal")
  end

  test "an active extraction is visible without changing the row's section", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    period = Nila.Gst.Calendar.closeable_period(Date.utc_today())

    {:ok, _dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: period, kind: "sales", file_keys: ["dumps/sales.pdf"]}
      )

    {:ok, view, _html} = live(conn, ~p"/today")

    assert has_element?(view, "#today-waiting_on_client #today-row-#{client.id}-#{period}")
    assert has_element?(view, "#today-processing-#{client.id}-#{period}", "extracting…")
  end

  test "a month row shows the deadline clock and no last ask yet", %{
    conn: conn,
    org: org,
    client: client
  } do
    seed_client_month(org, client, recon_with_2b_gap())

    {:ok, view, _html} = live(conn, ~p"/today")

    row = "#today-row-#{client.id}-#{@period}"
    assert has_element?(view, row)
    assert has_element?(view, "#{row}", "overdue")
    refute has_element?(view, "#{row}", "asked")
  end

  test "a client with nothing sent appears under waiting-on-client for the closeable period",
       %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/today")

    closeable = Nila.Gst.Calendar.closeable_period(Date.utc_today())

    assert has_element?(view, "#today-waiting_on_client")
    assert has_element?(view, "#today-row-#{client.id}-#{closeable}", "purchase not in")
    assert has_element?(view, "#draft-ask-#{client.id}-#{closeable}")
  end

  test "an automated channel shows Nila's ask count and keeps a manual override", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, client} =
      Clients.update_client(client, %{phone: "9876543210", chase_channel: "whatsapp"})

    period = Nila.Gst.Calendar.closeable_period(Date.utc_today())

    asks =
      for days_ago <- [3, 2] do
        {:ok, ask} =
          Chase.record_ask(
            %{org_id: org.id, client_id: client.id},
            %{kind: "month_open", period: period, body: "Please send it.", channel: "whatsapp"}
          )

        ask
        |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -days_ago, :day))
        |> Nila.Repo.update!()
      end

    assert length(asks) == 2
    {:ok, view, _html} = live(conn, ~p"/today")

    assert has_element?(
             view,
             "#automated-chase-#{client.id}-#{period}",
             "Nila asks — asked 2d ago · 2×"
           )

    assert has_element?(view, "#manual-chase-#{client.id}-#{period}", "Manual")
    refute has_element?(view, "#draft-ask-#{client.id}-#{period}")

    view |> element("#manual-chase-#{client.id}-#{period}") |> render_click()
    assert has_element?(view, "#chase-draft-modal")
  end

  test "an org with no clients gets one clear first action", %{conn: conn, client: client} do
    Nila.Repo.delete!(client)

    {:ok, view, _html} = live(conn, ~p"/today")

    assert has_element?(view, "#today-empty", "No clients yet")
    assert has_element?(view, "#today-add-first-client", "Add your first client")
  end

  test "a month with open decisions lands in needs-you; clean slots move it to waiting-on-senior",
       %{conn: conn, org: org, client: client} do
    seed_client_month(org, client, recon_with_2b_gap())

    {:ok, view, _html} = live(conn, ~p"/today")
    assert has_element?(view, "#today-needs_you #today-row-#{client.id}-#{@period}")

    clean_recon =
      recon_with_2b_gap()
      |> Map.put("in_2b_not_books", [])

    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        recon: clean_recon,
        summary: %{"buckets" => %{"matched" => 1}}
      })

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed"
      })

    {:ok, view, _html} = live(conn, ~p"/today")
    assert has_element?(view, "#today-waiting_on_senior #today-row-#{client.id}-#{@period}")
  end

  test "incomplete slots draft the month_open ask with client name and due date", %{
    conn: conn,
    org: org,
    client: client
  } do
    seed_client_month(org, client, recon_with_2b_gap())

    {:ok, view, _html} = live(conn, ~p"/today")

    view |> element("#draft-ask-#{client.id}-#{@period}") |> render_click()

    assert has_element?(view, "#chase-draft-modal")
    body = view |> element("#chase-draft-body") |> render()
    assert body =~ "Hi Breeze Tech"
    assert body =~ "October 2025 GST filing is open"
    assert body =~ "GSTR-1 is due 11 Nov 2025"
    assert has_element?(view, "#chase-copy-button")
  end

  test "complete slots with 2B gaps draft the missing_bills ask", %{
    conn: conn,
    org: org,
    client: client
  } do
    seed_client_month(org, client, recon_with_2b_gap())

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked"
      })

    {:ok, view, _html} = live(conn, ~p"/today")

    view |> element("#draft-ask-#{client.id}-#{@period}") |> render_click()

    body = view |> element("#chase-draft-body") |> render()
    assert body =~ "Sharma Steels — invoice INV-042, ₹11,800.00"
    assert body =~ "GSTR-3B for October 2025 is due 20 Nov 2025"
  end

  test "complete slots and no gaps show no draft button", %{
    conn: conn,
    org: org,
    client: client
  } do
    clean_recon = recon_with_2b_gap() |> Map.put("in_2b_not_books", [])
    seed_client_month(org, client, clean_recon)

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked"
      })

    {:ok, view, _html} = live(conn, ~p"/today")

    refute has_element?(view, "#draft-ask-#{client.id}-#{@period}")
  end

  test "mark as sent logs the ask, closes the modal, and updates the column", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    seed_client_month(org, client, recon_with_2b_gap())

    {:ok, view, _html} = live(conn, ~p"/today")

    view |> element("#draft-ask-#{client.id}-#{@period}") |> render_click()
    view |> element("#chase-mark-sent") |> render_click()

    refute has_element?(view, "#chase-draft-modal")
    assert render(view) =~ "Ask logged."
    assert has_element?(view, "#today-row-#{client.id}-#{@period}", "asked today")

    assert {:ok, ask} = Chase.last_ask(org.id, client.id, @period)
    assert ask.kind == "month_open"
    assert ask.channel == "manual"
    assert ask.sent_by_id == user.id
    assert ask.body =~ "Hi Breeze Tech"
  end

  test "redirects logged-out visitors to log in" do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/today")
  end
end
