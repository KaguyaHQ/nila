defmodule NilaWeb.MonthLiveSalesTest do
  use NilaWeb.ConnCase

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Purchase.Months, as: ClientMonths

  @period "2026-05"

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

    %{conn: log_in_user(conn, user), org: org, client: client}
  end

  test "renders the worked sales month with issue flags", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-page")
    assert has_element?(view, "#month-sales")
    assert has_element?(view, "#gstr1-inv-20\\/2026-27")
    assert has_element?(view, "#month-open-sales-issues", "sales issues →")
    assert render(view) =~ "open issues"
  end

  test "clicking an invoice shows its issues in the evidence modal", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2026-27") |> render_click()

    assert has_element?(view, "#gstr1-evidence-modal")
    assert has_element?(view, "#gstr1-evidence-modal p.line-clamp-2")
    assert render(view) =~ "Bill total doesn&#39;t tally"
  end

  test "confirming an issue resolves it; undo reopens it", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2026-27") |> render_click()

    view
    |> element("button[phx-value-target='20/2026-27:grand_total_mismatch']", "Checked")
    |> render_click()

    assert render(view) =~ "Confirmed"

    view
    |> element("button[phx-value-target='20/2026-27:grand_total_mismatch']", "Undo")
    |> render_click()

    refute render(view) =~ "Confirmed"
  end

  test "correcting a flagged field re-derives and clears the issue", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2026-27") |> render_click()

    view
    |> element("button[phx-value-field='printed_grand_total']", "Correct")
    |> render_click()

    view
    |> element("form[phx-submit='save_correct']")
    |> render_submit(%{"field" => "printed_grand_total", "value" => "76171.36"})

    refute render(view) =~ "Bill total doesn&#39;t tally"
  end

  test "mark reviewed appears once issues are cleared and flips the state", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute has_element?(view, "#gstr1-mark-reviewed")

    confirm_all_open_issues(view)

    assert has_element?(view, "#gstr1-mark-reviewed")
    view |> element("#gstr1-mark-reviewed") |> render_click()

    assert has_element?(view, "#gstr1-reviewed-badge")
    assert has_element?(view, "#month-bring-documents", "Bring in documents")
  end

  defp confirm_all_open_issues(view) do
    # Month-level issues confirm from the strip; invoice issues from the modal.
    for invoice <- ["20/2026-27"] do
      view |> element("#gstr1-inv-#{String.replace(invoice, "/", "\\/")}") |> render_click()

      while_confirmable(view)

      view
      |> element("#gstr1-evidence-modal button[phx-click='close-evidence']")
      |> render_click()
    end

    while_confirmable(view)
  end

  defp while_confirmable(view) do
    if has_element?(view, "button[phx-click='confirm_issue']") do
      view |> element("button[phx-click='confirm_issue']:first-of-type") |> render_click()
      while_confirmable(view)
    end
  end

  test "owner signs a reviewed month; the wall blocks decisions; reopen lifts it", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#gstr1-mark-reviewed") |> render_click()

    assert has_element?(view, "#gstr1-signoff-button")
    view |> element("#gstr1-signoff-button") |> render_click()

    assert has_element?(view, "#gstr1-signoff-banner")
    assert has_element?(view, "#month-file-gstr1[href='#gstr1-signoff-banner']")
    assert has_element?(view, "#gstr1-guide-download-json", "Download JSON")
    assert has_element?(view, "#gstr1-download-json.btn-outline")
    assert has_element?(view, "#gstr1-signoff-banner a[target='_blank'][rel='noopener']")
    assert has_element?(view, "#gstr1-filed-arn[autofocus]")
    refute has_element?(view, "#gstr1-signoff-button")
    refute has_element?(view, "button[phx-click='confirm_issue']")

    view |> element("#gstr1-reopen-signoff") |> render_click()

    refute has_element?(view, "#gstr1-signoff-banner")
    assert has_element?(view, "#gstr1-signoff-button")
  end

  test "marking a signed GSTR-1 filed records the ARN and hides reopen", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#gstr1-mark-reviewed") |> render_click()
    view |> element("#gstr1-signoff-button") |> render_click()

    view
    |> element("#gstr1-mark-filed")
    |> render_submit(%{"arn" => "AA331025000001"})

    assert has_element?(view, "#gstr1-filed-note")
    assert render(view) =~ "AA331025000001"
    refute has_element?(view, "#gstr1-mark-filed")
    refute has_element?(view, "#gstr1-reopen-signoff")
  end

  test "a member cannot see the sign-off button", %{org: org, client: client} do
    member = Nila.AccountsFixtures.user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, member.id, "member")
    conn = log_in_user(build_conn(), member)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#gstr1-mark-reviewed") |> render_click()

    refute has_element?(view, "#gstr1-signoff-button")
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
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    confirm_all_open_issues(view)
    view |> element("#gstr1-mark-reviewed") |> render_click()
    view |> element("#gstr1-signoff-button") |> render_click()

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
    assert body["fp"] == "052026"
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
