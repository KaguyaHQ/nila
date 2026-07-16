defmodule NilaWeb.GstExceptionsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.{ClientMonths, Recon, Register, Resolutions, Signoffs}

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

    render_click(view, "confirm_pair", %{"id" => "page_01"})
    assert render(view) =~ "Month is signed off"

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert Resolutions.list(month.id) == []
  end

  test "renders the queue and the side-by-side diff", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    assert has_element?(view, "#gst-exception-queue")
    assert has_element?(view, "#queue-page_01")
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
