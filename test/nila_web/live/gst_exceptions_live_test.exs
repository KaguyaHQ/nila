defmodule NilaWeb.GstExceptionsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.{ClientMonths, Recon, Register, Resolutions}

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

    %{conn: log_in_user(conn, user), org: org, client: client}
  end

  test "renders the queue and the side-by-side diff", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    assert has_element?(view, "#gst-exception-queue")
    assert has_element?(view, "#queue-page_01")
    assert has_element?(view, "#gst-exception-detail")
    assert render(view) =~ "1134"
    assert render(view) =~ "CHN-SER-1134"
  end

  test "confirm clears the exception from the queue", %{conn: conn, client: client, org: org} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    view
    |> element("button", "Confirm — same bill")
    |> render_click()

    refute has_element?(view, "#queue-page_01")
    assert has_element?(view, "#gst-exceptions-empty")

    month = ClientMonths.get_by_period(org.id, client.id, @period) |> elem(1)
    assert [res] = Resolutions.list(month.id)
    assert res.verb == "confirm_pair"
    assert res.books_id == "page_01"

    workings = Resolutions.workings(month)
    assert [row] = workings.recon["matched"]
    assert "human_confirmed" in row["match_basis"]
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

    refute has_element?(view, "#queue-page_01")

    month = ClientMonths.get_by_period(org.id, client.id, @period) |> elem(1)
    workings = Resolutions.workings(month)
    assert [row] = workings.recon["matched"]
    assert "invoice_number" in row["match_basis"]
  end

  test "another org cannot open the month", %{conn: conn, client: client} do
    %{user: other_user} = user_with_org_fixture()

    assert {:error, {:live_redirect, %{to: "/today"}}} =
             conn
             |> log_in_user(other_user)
             |> live(~p"/gst/#{client.id}/#{@period}/exceptions")
  end
end
