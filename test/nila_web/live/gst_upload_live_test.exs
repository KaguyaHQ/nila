defmodule NilaWeb.GstUploadLiveTest do
  use NilaWeb.ConnCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.{Dumps, DumpWorker}

  @period "2025-10"
  @period_month "10"
  @period_year "2025"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  defp submit(view, client) do
    view
    |> form("#gst-upload-form",
      intake: %{client_id: client.id, period_month: @period_month, period_year: @period_year}
    )
    |> render_submit()
  end

  test "mounts with the intake form and all three drops", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    assert has_element?(view, "#gst-upload-page")
    assert has_element?(view, "#gst-upload-form")
    assert has_element?(view, "#gst-upload-sales")
    assert has_element?(view, "#gst-upload-purchase")
    assert has_element?(view, "#gst-upload-gstr2b")
    assert has_element?(view, "#gst-upload-submit")
  end

  test "prefills client and period from query params", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload?client_id=#{client.id}&period=2025-08")

    html = view |> element("#gst-upload-form") |> render()
    assert html =~ ~s(selected="" value="#{client.id}")
    assert html =~ ~s(selected="" value="08")
    assert html =~ ~s(selected="" value="2025")
  end

  test "another org's client id does not prefill", %{conn: conn} do
    %{org: other_org} = user_with_org_fixture(%{org: %{gstin: "27AAPFU0939F1ZV"}})

    {:ok, other_client} =
      Clients.create_client(%{org_id: other_org.id, name: "Rival Corp", type: "company"})

    {:ok, view, _html} = live(conn, ~p"/gst/upload?client_id=#{other_client.id}")

    html = view |> element("#gst-upload-form") |> render()
    refute html =~ ~s(selected="" value="#{other_client.id}")
  end

  test "one pile creates one dump and one job", %{conn: conn, org: org, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    sales =
      file_input(view, "#gst-upload-form", :sales, [
        %{name: "sales.pdf", content: "%PDF-1.4 fake sales", type: "application/pdf"}
      ])

    assert render_upload(sales, "sales.pdf") =~ "sales.pdf"

    submit(view, client)

    assert has_element?(view, "#gst-upload-progress")

    assert [dump] = Dumps.list(org.id, client.id, @period)
    assert dump.kind == "sales"
    assert dump.status == "received"
    assert_enqueued(worker: DumpWorker, args: %{dump_id: dump.id})
  end

  test "a mixed drop creates a dump per pile", %{conn: conn, org: org, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    purchase =
      file_input(view, "#gst-upload-form", :purchase, [
        %{name: "bills.pdf", content: "%PDF-1.4 fake", type: "application/pdf"}
      ])

    gstr2b =
      file_input(view, "#gst-upload-form", :gstr2b, [
        %{name: "gstr2b.json", content: ~s({"docdata":{"b2b":[]}}), type: "application/json"}
      ])

    render_upload(purchase, "bills.pdf")
    render_upload(gstr2b, "gstr2b.json")

    submit(view, client)

    kinds = org.id |> Dumps.list(client.id, @period) |> Enum.map(& &1.kind) |> Enum.sort()
    assert kinds == ["gstr2b", "purchase"]

    for dump <- Dumps.list(org.id, client.id, @period) do
      assert_enqueued(worker: DumpWorker, args: %{dump_id: dump.id})
    end
  end

  test "rejects a submit with no files attached", %{conn: conn, org: org, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    submit(view, client)

    assert has_element?(view, "#gst-upload-error")
    assert Dumps.list(org.id, client.id, @period) == []
    refute_enqueued(worker: DumpWorker)
  end

  test "progress narrates per dump and offers the month when done", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    sales =
      file_input(view, "#gst-upload-form", :sales, [
        %{name: "sales.pdf", content: "%PDF-1.4 fake sales", type: "application/pdf"}
      ])

    render_upload(sales, "sales.pdf")
    submit(view, client)

    [dump] = Dumps.list(org.id, client.id, @period)

    assert has_element?(view, "#gst-dump-#{dump.id}")
    assert render(view) =~ "Queued"

    # The worker runs and broadcasts; drive it inline and let the view catch up.
    assert :ok = perform_job(DumpWorker, %{"dump_id" => dump.id})

    assert render(view) =~ "Done"
    assert has_element?(view, "#gst-upload-open-month")

    view |> element("#gst-upload-open-month") |> render_click()
    assert_redirect(view, "/gst/#{client.id}/#{@period}")
  end
end
