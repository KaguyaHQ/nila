defmodule NilaWeb.Gst.MonthLiveSalesIntakeTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures
  import NilaWeb.Gst.MonthLiveSalesHelpers, only: [confirm_all_open_issues: 1]

  alias Nila.Clients
  alias Nila.Gst.Intake.{Dump, Dumps}
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

  test "an in-flight dump appears and clears through the month subscription", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

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
      {:gst_dump_progress, dump.id, client.id, @period, "purchase",
       {:done, client.id, @period, []}}
    )

    refute has_element?(view, "#month-dump-#{dump.id}")
  end

  test "a previously held sales packet can be released without reopening approval", %{
    conn: conn,
    org: org,
    client: client
  } do
    straggler = work_dump!(org, client, @period, "sales", "%PDF-1.4 late")
    straggler |> Dump.changeset(%{status: "held"}) |> Nila.Repo.update!()
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")
    assert has_element?(view, "#month-dump-release-#{straggler.id}")
    view |> element("#month-dump-release-#{straggler.id}") |> render_click()
    assert [job] = all_enqueued(worker: Nila.Gst.Intake.DumpWorker)
    assert job.args["dump_id"] == straggler.id
  end

  # A failed packet is concrete unresolved intake, not a request for a generic
  # client attestation. It blocks until a senior deliberately stops waiting.
  test "a failed sales packet blocks the month until a senior stops waiting for it", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{period: @period, kind: "sales", file_keys: ["dumps/unreadable.pdf"]}
      )

    failed = dump |> Dump.changeset(%{status: "failed"}) |> Nila.Repo.update!()

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")
    confirm_all_open_issues(view)

    assert has_element?(view, "#month-dump-#{failed.id}", "Extraction failed")

    assert has_element?(
             view,
             "#month-exit-gstr1",
             "Blocked · 1 sales packet remains unresolved"
           )

    assert has_element?(view, "#gstr1-filing-status", "Provisional")
    refute has_element?(view, "#gstr1-filing-status", "Ready for approval")
    refute has_element?(view, "#month-door-sign-r1")

    view |> element("#month-dump-abandon-#{failed.id}") |> render_click()

    assert render(view) =~ "Stopped waiting for that packet"
    refute has_element?(view, "#month-dump-abandon-#{failed.id}")

    assert has_element?(view, "#gstr1-primary-handoff")

    assert Nila.Repo.get!(Dump, failed.id).status == "discarded"
  end

  test "a member cannot stop waiting for a failed packet", %{org: org, client: client} do
    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{period: @period, kind: "sales", file_keys: ["dumps/unreadable.pdf"]}
      )

    failed = dump |> Dump.changeset(%{status: "failed"}) |> Nila.Repo.update!()

    member = user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, member.id, "member")
    member_conn = log_in_user(Phoenix.ConnTest.build_conn(), member)

    {:ok, view, _html} = live(member_conn, "/gst/#{client.id}/#{@period}?track=sales")

    # Abandoning unresolved intake is a senior-only audit decision. The control
    # is hidden, and the event is refused even when the client is driven directly.
    refute has_element?(view, "#month-dump-abandon-#{failed.id}")

    render_click(view, "abandon-dump", %{"dump-id" => failed.id})

    assert render(view) =~ "Only a senior can stop waiting for a packet."
    assert Nila.Repo.get!(Dump, failed.id).status == "failed"
  end
end
