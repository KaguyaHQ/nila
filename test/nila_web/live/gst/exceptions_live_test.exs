defmodule NilaWeb.Gst.ExceptionsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.Purchase.{Groups, Register}
  alias Nila.Gst.Purchase.Months
  alias Nila.Gst.Purchase.Reconciliation

  test "the retired exceptions destination redirects to the month", %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Breeze", type: "company"})
    recon = Reconciliation.reconcile([], [])

    {:ok, _month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2026-08",
        state: "worked",
        register_rows: [],
        recon: recon,
        summary: Register.summary([], Groups.build(recon))
      })

    conn = log_in_user(conn, user)

    assert {:error, {:live_redirect, %{to: path}}} =
             live(conn, ~p"/gst/#{client.id}/2026-08/exceptions")

    assert path == ~p"/gst/#{client.id}/2026-08"
  end
end
