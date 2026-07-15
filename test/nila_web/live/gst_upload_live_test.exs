defmodule NilaWeb.GstUploadLiveTest do
  use NilaWeb.ConnCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Phoenix.LiveViewTest

  alias Nila.Clients

  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    %{conn: log_in_user(conn, user), org: org, client: client}
  end

  test "mounts with the upload form and both file inputs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    assert has_element?(view, "#gst-upload-page")
    assert has_element?(view, "#gst-upload-form")
    assert has_element?(view, "#gst-upload-bills")
    assert has_element?(view, "#gst-upload-gstr2b")
    assert has_element?(view, "#gst-upload-submit")
  end

  test "accepts two uploads, enqueues the worker, and shows progress", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    bills =
      file_input(view, "#gst-upload-form", :bills, [
        %{name: "bills.pdf", content: "%PDF-1.4 fake", type: "application/pdf"}
      ])

    gstr2b =
      file_input(view, "#gst-upload-form", :gstr2b, [
        %{name: "gstr2b.json", content: ~s({"docdata":{"b2b":[]}}), type: "application/json"}
      ])

    assert render_upload(bills, "bills.pdf") =~ "bills.pdf"
    assert render_upload(gstr2b, "gstr2b.json") =~ "gstr2b.json"

    view
    |> form("#gst-upload-form", month: %{client_id: client.id, period: @period})
    |> render_submit()

    assert has_element?(view, "#gst-upload-progress")

    assert_enqueued(
      worker: Nila.Gst.MonthWorker,
      args: %{org_id: org.id, client_id: client.id, period: @period}
    )
  end

  test "rejects a submit with no files attached", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    view
    |> form("#gst-upload-form", month: %{client_id: client.id, period: @period})
    |> render_submit()

    assert has_element?(view, "#gst-upload-error")
    refute_enqueued(worker: Nila.Gst.MonthWorker)
  end
end
