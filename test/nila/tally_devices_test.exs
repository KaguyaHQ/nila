defmodule Nila.TallyDevicesTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.TallyDevices

  test "creates a device with a one-time credential and authenticates it" do
    %{org: org} = user_with_org_fixture()

    assert {:ok, device, token} =
             TallyDevices.create_device(org, %{name: "Front desk PC"})

    assert device.org_id == org.id
    assert device.name == "Front desk PC"
    assert is_binary(device.token_hash)
    refute device.token_hash == token

    assert authenticated = TallyDevices.authenticate_device(token)
    assert authenticated.id == device.id
    assert authenticated.org.id == org.id
    assert TallyDevices.authenticate_device("not-the-token") == nil
  end

  test "a revoked credential no longer authenticates" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    assert {:ok, revoked} = TallyDevices.revoke_device(device)
    assert revoked.revoked_at
    assert TallyDevices.authenticate_device(token) == nil
  end

  test "a device belonging to a suspended organization cannot authenticate" do
    %{org: org} = user_with_org_fixture()
    {:ok, _device, token} = TallyDevices.create_device(org, %{name: "Suspended PC"})

    org
    |> Nila.Orgs.Org.changeset(%{status: "suspended"})
    |> Nila.Repo.update!()

    assert TallyDevices.authenticate_device(token) == nil
  end

  test "requires a useful device name" do
    %{org: org} = user_with_org_fixture()

    assert {:error, changeset} = TallyDevices.create_device(org, %{name: "  "})
    assert "can't be blank" in errors_on(changeset).name
  end
end
