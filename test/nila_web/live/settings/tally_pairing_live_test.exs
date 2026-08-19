defmodule NilaWeb.Settings.TallyPairingLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.AccountsFixtures

  alias Nila.TallyDevices

  test "an owner approves the named computer for the current workspace", %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, started} = TallyDevices.create_pairing(%{device_name: "Accounts PC"})

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/settings/connectors/tally/pair/#{started.approval_code}")

    assert has_element?(view, "#tally-pairing-device-name", "Accounts PC")
    assert has_element?(view, "#tally-pairing-pending", org.name)

    view |> element("#approve-tally-pairing") |> render_click()

    assert has_element?(view, "#tally-pairing-approved")
    refute has_element?(view, "#approve-tally-pairing")
  end

  test "an invalid code reveals no pairing details", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/settings/connectors/tally/pair/not-a-real-code")

    assert has_element?(view, "#tally-pairing-unavailable")
    refute has_element?(view, "#tally-pairing-device-name")
  end

  test "an operator cannot approve a computer", %{conn: conn} do
    %{user: user} = user_with_org_fixture(%{role: "member"})
    {:ok, started} = TallyDevices.create_pairing(%{device_name: "Accounts PC"})

    assert {:error, {:redirect, %{to: "/today"}}} =
             conn
             |> log_in_user(user)
             |> live(~p"/settings/connectors/tally/pair/#{started.approval_code}")
  end

  test "a logged-out visitor is sent to sign in", %{conn: conn} do
    {:ok, started} = TallyDevices.create_pairing(%{device_name: "Accounts PC"})

    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(conn, ~p"/settings/connectors/tally/pair/#{started.approval_code}")
  end
end
