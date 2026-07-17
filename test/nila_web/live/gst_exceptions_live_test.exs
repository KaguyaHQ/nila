defmodule NilaWeb.GstExceptionsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.{Chase, ClientMonths, Recon, Register, Resolutions, Signoffs}

  @period "2025-10"
  @gstin "33AAACS1234A1Z9"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: @gstin
      })

    books = %{
      "id" => "page_01",
      "vendor_name" => "Sharma Steels",
      "vendor_gstin" => @gstin,
      "invoice_number" => "1134",
      "invoice_date" => ~D[2025-10-05],
      "taxable_paise" => 1_000_000,
      "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
      "total_paise" => 1_180_000,
      "images" => [],
      "pages" => [1]
    }

    g2b = %{
      "vendor_gstin" => @gstin,
      "vendor_name" => "SHARMA STEELS",
      "invoice_number" => "CHN-SER-1134",
      "invoice_date" => ~D[2025-10-05],
      "taxable_paise" => 1_000_000,
      "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
      "total_paise" => 1_180_000,
      "pos" => "33"
    }

    recon = Recon.reconcile([books], [g2b])
    rows = Register.rows([books], recon, %{})

    {:ok, _month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  defp books(attrs) do
    Map.merge(
      %{
        "id" => "books_01",
        "vendor_name" => "Sharma Steels",
        "vendor_gstin" => @gstin,
        "invoice_number" => "INV-001",
        "invoice_date" => ~D[2025-10-05],
        "taxable_paise" => 1_000_000,
        "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
        "total_paise" => 1_180_000,
        "images" => [],
        "pages" => [1]
      },
      attrs
    )
  end

  defp g2b(attrs) do
    Map.merge(
      %{
        "vendor_gstin" => @gstin,
        "vendor_name" => "SHARMA STEELS",
        "invoice_number" => "INV-001",
        "invoice_date" => ~D[2025-10-05],
        "taxable_paise" => 1_000_000,
        "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
        "total_paise" => 1_180_000,
        "pos" => "33"
      },
      attrs
    )
  end

  defp put_recon!(org, client, period, books, recon) do
    rows = Register.rows(books, recon, %{})

    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    month
  end

  test "a signed-off month hides the verbs and rejects resolutions server-side", %{
    conn: conn,
    user: user,
    org: org,
    client: client
  } do
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    scope = Nila.Accounts.Scope.for_user(user)
    {:ok, _} = Signoffs.sign_off(month, scope)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    refute has_element?(view, "button", "Confirm — same bill")

    for {event, params} <- [
          {"confirm_pair", %{"id" => "page_01"}},
          {"reject_all", %{"id" => "page_01"}},
          {"accept_unmatched", %{"id" => "page_01", "reason" => "await_2b"}},
          {"dismiss_2b", %{"id" => "page_01"}}
        ] do
      render_click(view, event, params)
      assert render(view) =~ "Month is signed off"
    end

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert Resolutions.list(month.id) == []
  end

  test "renders the queue and the side-by-side diff", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    assert has_element?(view, "#gst-exception-queue")
    assert has_element?(view, "#queue-page_01")
    assert has_element?(view, "#queue-page_01 .truncate")
    assert has_element?(view, "#gst-exception-detail")
    assert render(view) =~ "1134"
    assert render(view) =~ "CHN-SER-1134"
  end

  test "confirm marks the exception resolved in place with its outcome", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    view
    |> element("button", "Confirm — same bill")
    |> render_click()

    # Stays visible (not vanished), marked done, register updated, all-cleared banner shown.
    assert has_element?(view, "#queue-page_01")
    assert render(view) =~ "Confirmed — same bill"
    assert has_element?(view, "#gst-exceptions-cleared")
    assert has_element?(view, "#gst-exceptions-progress")

    month = ClientMonths.get_by_period(org.id, client.id, @period) |> elem(1)
    assert [res] = Resolutions.list(month.id)
    assert res.verb == "confirm_pair"
    assert res.books_id == "page_01"

    workings = Resolutions.workings(month)
    assert [row] = workings.recon["matched"]
    assert "human_confirmed" in row["match_basis"]
  end

  test "undo reopens a resolved exception", %{conn: conn, client: client, org: org} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    view |> element("button", "Confirm — same bill") |> render_click()
    assert render(view) =~ "Confirmed — same bill"

    view |> element("#gst-exception-outcome button", "Undo") |> render_click()

    # Back to open: the verb buttons return, the register match is gone.
    assert has_element?(view, "button", "Confirm — same bill")

    month = ClientMonths.get_by_period(org.id, client.id, @period) |> elem(1)
    workings = Resolutions.workings(month)
    assert workings.recon["matched"] == []
    assert length(workings.recon["needs_human"]) == 1
  end

  test "correcting the invoice number auto-matches via the engine", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    view |> element("button", "Correct the number") |> render_click()

    view
    |> form("#gst-exception-detail form", %{value: "CHN-SER-1134"})
    |> render_submit()

    assert render(view) =~ "Corrected"
    assert has_element?(view, "#gst-exception-outcome")

    month = ClientMonths.get_by_period(org.id, client.id, @period) |> elem(1)
    workings = Resolutions.workings(month)
    assert [row] = workings.recon["matched"]
    assert "invoice_number" in row["match_basis"]
  end

  test "a fuzzy-name single-candidate exception is also resolvable (not just invoice_number_mismatch)",
       %{
         conn: conn,
         org: org,
         client: client
       } do
    # No valid vendor GSTIN + a fuzzy name + exact value -> fuzzy_name_weak
    # corroboration with one candidate: must be resolvable, same as Bikezone.
    books = %{
      "id" => "fz_01",
      "vendor_name" => "Maheswari & Co",
      "vendor_gstin" => nil,
      "invoice_number" => "1",
      "invoice_date" => ~D[2025-11-05],
      "taxable_paise" => 238_100,
      "tax_paise" => %{"cgst" => 24_400, "sgst" => 24_400, "igst" => 0},
      "total_paise" => 286_900,
      "images" => [],
      "pages" => [1]
    }

    g2b = %{
      "vendor_gstin" => "33APZPP6215J1ZB",
      "vendor_name" => "MAHESWARI AND CO",
      "invoice_number" => "125",
      "invoice_date" => ~D[2025-11-05],
      "taxable_paise" => 238_100,
      "tax_paise" => %{"cgst" => 24_400, "sgst" => 24_400, "igst" => 0},
      "total_paise" => 286_900,
      "pos" => "33"
    }

    recon = Recon.reconcile([books], [g2b])
    assert [%{"reason" => %{"code" => "fuzzy_name_weak_corroboration"}}] = recon["needs_human"]
    rows = Register.rows([books], recon, %{})

    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2025-12",
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/2025-12/exceptions")
    assert has_element?(view, "button", "Confirm — same bill")
  end

  test "ambiguous candidates can be chosen or all rejected into unmatched verbs", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-01"
    books = books(%{"id" => "ambiguous_01", "invoice_number" => "DUP-1"})
    first = g2b(%{"invoice_number" => "DUP-1", "total_paise" => 1_180_000})
    second = g2b(%{"invoice_number" => "DUP-1", "total_paise" => 1_180_100})
    recon = Recon.reconcile([books], [first, second])
    put_recon!(org, client, period, [books], recon)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

    assert has_element?(view, "#gst-candidate-1")
    assert has_element?(view, "#gst-candidate-2")
    refute render(view) =~ "isn&#39;t wired"

    view |> element("#gst-candidate-2 button", "This one") |> render_click()
    assert render(view) =~ "Matched to the chosen 2B row"

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, period)
    assert [chosen] = Resolutions.list(month.id)
    assert chosen.gstr2b_ref == Recon.gstr2b_ref(second)

    view |> element("#gst-exception-outcome button", "Undo") |> render_click()
    view |> element("#gst-reject-all-candidates", "None of these") |> render_click()

    assert has_element?(view, "#gst-accept-await-2b")
    assert has_element?(view, "#gst-accept-not-claimable")

    assert Enum.count(Resolutions.list(month.id), &(&1.verb == "reject_pair")) == 2
  end

  test "accepting an unmatched bill removes it from decision counts and ITC", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-02"
    books = books(%{"id" => "unmatched_01", "invoice_number" => "BOOK-ONLY"})
    recon = Recon.reconcile([books], [])
    put_recon!(org, client, period, [books], recon)

    {:ok, month_view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")
    assert has_element?(month_view, "#gst-stat-need-decision", "1")

    {:ok, today, _html} = live(conn, ~p"/today")
    assert has_element?(today, "#today-row-#{client.id}-#{period}", "1 to decide")

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")
    assert has_element?(view, "#gst-accept-await-2b")
    assert has_element?(view, "button", "Correct the number")
    refute render(view) =~ "isn&#39;t wired"

    view |> element("#gst-accept-await-2b") |> render_click()
    assert render(view) =~ "Kept — awaiting vendor&#39;s 2B"

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, period)
    workings = Resolutions.workings(month)
    assert workings.summary["accepted_unmatched"] == 1
    assert workings.itc["claimable_paise"] == 0

    assert Enum.any?(Resolutions.list(month.id), fn resolution ->
             resolution.verb == "accept_unmatched" and
               resolution.payload["reason"] == "await_2b"
           end)

    {:ok, today, _html} = live(conn, ~p"/today")
    refute has_element?(today, "#today-row-#{client.id}-#{period}", "to decide")

    {:ok, month_view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")
    assert has_element?(month_view, "#gst-stat-need-decision", "0")

    view |> element("#gst-exception-outcome button", "Undo") |> render_click()
    assert has_element?(view, "#gst-accept-await-2b")

    view |> element("#gst-accept-not-claimable") |> render_click()
    assert render(view) =~ "Not claimable this month"
  end

  test "a 2B-only bill can be chased, dismissed, and reopened", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-03"

    gstr2b =
      g2b(%{
        "vendor_name" => "PORTAL VENDOR",
        "invoice_number" => "PORTAL-9",
        "total_paise" => 2_360_000
      })

    recon = Recon.reconcile([], [gstr2b])
    month = put_recon!(org, client, period, [], recon)
    ref = Recon.gstr2b_ref(gstr2b)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

    assert has_element?(view, "#queue-g2b-#{ref}")
    assert has_element?(view, "#gst-exceptions-progress", "0 of 1 resolved")
    assert has_element?(view, "#gst-exception-gstr2b", "Reported in GSTR-2B")
    refute render(view) =~ "isn&#39;t wired"

    view |> element("#gst-ask-client") |> render_click()
    assert has_element?(view, "#gst-missing-bill-modal")
    assert render(view) =~ "PORTAL VENDOR"
    assert render(view) =~ "PORTAL-9"

    view |> element("#gst-missing-bill-mark-sent") |> render_click()
    assert render(view) =~ "asked today"
    assert {:ok, ask} = Chase.last_ask(org.id, client.id, period)
    assert ask.body =~ "PORTAL-9"

    view |> element("#gst-dismiss-2b") |> render_click()
    assert render(view) =~ "Dismissed — not ours"
    assert Enum.any?(Resolutions.list(month.id), &(&1.verb == "dismiss_2b"))
    assert Resolutions.workings(month).recon["in_2b_not_books"] == []
    assert Chase.gaps(month).in_2b_not_books == []

    view |> element("#gst-exception-outcome button", "Undo") |> render_click()
    assert has_element?(view, "#gst-dismiss-2b")
  end

  test "an unknown books reason still falls back to recorded unmatched decisions", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-04"
    books = books(%{"id" => "future_01", "invoice_number" => "FUTURE-1"})
    recon = Recon.reconcile([books], [])

    recon =
      update_in(recon, ["in_books_not_2b", Access.at(0), "reason"], fn reason ->
        %{reason | "code" => "future_engine_reason"}
      end)

    put_recon!(org, client, period, [books], recon)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

    assert has_element?(view, "#gst-accept-await-2b")
    assert has_element?(view, "#gst-accept-not-claimable")
    refute render(view) =~ "isn&#39;t wired"
  end

  test "another org cannot open the month", %{conn: conn, client: client} do
    %{user: other_user} = user_with_org_fixture()

    assert {:error, {:live_redirect, %{to: "/today"}}} =
             conn
             |> log_in_user(other_user)
             |> live(~p"/gst/#{client.id}/#{@period}/exceptions")
  end

  test "blocking a recommended duplicate credit reduces claimable ITC and logs it", %{
    conn: conn,
    org: org,
    client: client
  } do
    # Two identical scans of the same bill -> the flag engine recomputes a
    # duplicate_invoice flag, and the ITC panel recommends blocking one copy.
    dup = fn id ->
      %{
        "id" => id,
        "vendor_name" => "National Electric",
        "vendor_gstin" => @gstin,
        "invoice_number" => "254111",
        "invoice_date" => ~D[2025-10-06],
        "taxable_paise" => 3_500,
        "tax_paise" => %{"cgst" => 315, "sgst" => 315, "igst" => 0},
        "total_paise" => 4_130,
        "images" => [],
        "pages" => [if(id == "d1", do: 3, else: 9)]
      }
    end

    g2b = %{
      "vendor_gstin" => @gstin,
      "invoice_number" => "254111",
      "taxable_paise" => 3_500,
      "tax_paise" => %{"cgst" => 315, "sgst" => 315, "igst" => 0},
      "total_paise" => 4_130,
      "pos" => "33"
    }

    recon = Recon.reconcile([dup.("d1"), dup.("d2")], [g2b])
    rows = Register.rows([dup.("d1"), dup.("d2")], recon, %{})

    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2025-11",
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/2025-11/exceptions")

    assert has_element?(view, "#gst-itc-panel")
    block_id = "d1:duplicate_invoice"

    view
    |> element(~s|button[phx-click="block_itc"][phx-value-block-id="#{block_id}"]|)
    |> render_click()

    workings = Resolutions.workings(month)
    # one of two ₹6.30 copies blocked -> ₹6.30 (630 paise) removed
    assert workings.itc["blocked_paise"] == 630
    assert [res] = Resolutions.list(month.id)
    assert res.verb == "block_itc"
    assert res.payload["block_id"] == block_id
  end
end
