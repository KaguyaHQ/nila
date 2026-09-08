defmodule NilaWeb.Gst.DemoResetTest do
  use NilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Nila.{DemoSession, Repo}
  alias Nila.Gst.Sales.Months

  setup %{conn: conn} do
    %{user: user, org: org, membership: membership} =
      user_with_org_fixture(%{user: %{email: "spare.me1180650@gmail.com"}})

    {:ok, client} = DemoSession.setup(org.id)
    {:ok, month} = Months.upsert(%{org_id: org.id, client_id: client.id, period: "2026-06"})

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client,
      month: month,
      membership: membership
    }
  end

  test "requires confirmation, can cancel, then resets and opens empty June", c do
    {:ok, view, _} = live(c.conn, ~p"/gst/#{c.client.id}/2026-06/sales")
    assert has_element?(view, "#demo-reset-open")
    render_click(view, "confirm-demo-reset")
    assert Repo.get(Nila.Gst.Sales.Month, c.month.id)
    view |> element("#demo-reset-open") |> render_click()
    assert has_element?(view, "#demo-reset-confirmation", "June 2026")
    view |> element("#demo-reset-cancel") |> render_click()
    refute has_element?(view, "#demo-reset-confirmation")
    assert Repo.get(Nila.Gst.Sales.Month, c.month.id)
    view |> element("#demo-reset-open") |> render_click()
    view |> element("#demo-reset-confirm") |> render_click()
    assert_redirect(view, ~p"/gst/#{c.client.id}/2026-06/sales")
    refute Repo.get(Nila.Gst.Sales.Month, c.month.id)
    assert Repo.get(Nila.Clients.Client, c.client.id)

    assert {:ok, %{counts: %{months: 0}, reset_check: :ok}} =
             DemoSession.inspect_session(c.org.id, c.client.id)
  end

  test "another owner cannot reveal or invoke reset", c do
    user = user_fixture()
    {:ok, _} = Nila.Orgs.add_user(c.org, user.id, "owner")
    {:ok, view, _} = live(log_in_user(build_conn(), user), ~p"/gst/#{c.client.id}/2026-06/sales")
    refute has_element?(view, "#demo-client-actions")
    render_click(view, "open-demo-reset")
    refute has_element?(view, "#demo-reset-confirmation")
    render_click(view, "confirm-demo-reset")
    assert Repo.get(Nila.Gst.Sales.Month, c.month.id)

    assert {:error, :forbidden} =
             DemoSession.reset_for_user(Nila.Accounts.Scope.for_user(user), c.client.id)
  end

  test "a normal client and a client in another organisation cannot be reset", c do
    {:ok, normal} =
      Nila.Clients.create_client(%{org_id: c.org.id, name: "Real client", type: "company"})

    {:ok, view, _} = live(c.conn, ~p"/gst/#{normal.id}/2026-06/sales")
    refute has_element?(view, "#demo-client-actions")
    render_click(view, "open-demo-reset")
    refute has_element?(view, "#demo-reset-confirmation")
    other_org = org_fixture()
    {:ok, other} = DemoSession.setup(other_org.id)
    scope = Nila.Accounts.Scope.for_user(c.user)
    assert {:error, :forbidden} = DemoSession.reset_for_user(scope, normal.id)
    assert {:error, :forbidden} = DemoSession.reset_for_user(scope, other.id)
  end

  test "rechecks account permission after confirmation was opened", c do
    {:ok, view, _} = live(c.conn, ~p"/gst/#{c.client.id}/2026-06/sales")
    view |> element("#demo-reset-open") |> render_click()
    c.membership |> Nila.Orgs.Membership.role_changeset("member") |> Repo.update!()
    view |> element("#demo-reset-confirm") |> render_click()
    assert has_element?(view, "[role=alert]", "Reset is not available")
    assert Repo.get(Nila.Gst.Sales.Month, c.month.id)
  end

  test "running extraction is refused without clearing data", c do
    {:ok, dump} =
      Nila.Gst.Intake.Dumps.record(
        %{org_id: c.org.id, client_id: c.client.id},
        %{period: "2026-06", kind: "sales", status: "extracting", file_keys: []}
      )

    {:ok, view, _} = live(c.conn, ~p"/gst/#{c.client.id}/2026-06/sales")
    view |> element("#demo-reset-open") |> render_click()
    view |> element("#demo-reset-confirm") |> render_click()
    assert has_element?(view, "[role=alert]", "Invoices are still processing")
    assert Repo.get(Nila.Gst.Intake.Dump, dump.id)
    assert Repo.get(Nila.Gst.Sales.Month, c.month.id)
  end
end
