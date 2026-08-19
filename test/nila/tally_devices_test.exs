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

  test "reports the currently open companies and closes companies absent from the next report" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    assert {:ok, [nila, archive]} =
             TallyDevices.report_companies(device, [
               %{"name" => "Nila", "tally_guid" => "company-nila"},
               %{"name" => "Archive", "tally_guid" => "company-archive"}
             ])

    assert nila.is_open
    assert archive.is_open
    assert Enum.map(TallyDevices.list_open_companies(org.id), & &1.name) == ["Archive", "Nila"]

    assert {:ok, [updated]} =
             TallyDevices.report_companies(device, [
               %{"name" => "Nila Pvt Ltd", "tally_guid" => "company-nila"}
             ])

    assert updated.id == nila.id
    assert updated.name == "Nila Pvt Ltd"
    assert Enum.map(TallyDevices.list_open_companies(org.id), & &1.name) == ["Nila Pvt Ltd"]

    assert :ok = TallyDevices.mark_companies_closed(device.id)
    assert TallyDevices.list_open_companies(org.id) == []
  end

  test "does not resolve another organization's reported company" do
    %{org: org} = user_with_org_fixture()
    %{org: other_org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Office PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [%{"name" => "Nila", "tally_guid" => "nila"}])

    assert {:ok, selected} = TallyDevices.get_open_company(org.id, company.id)
    assert selected.device.id == device.id
    assert {:error, :not_found} = TallyDevices.get_open_company(other_org.id, company.id)
  end

  test "an older disconnect cannot close companies from a newer connection" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})
    older = ~U[2026-08-19 10:00:00.000000Z]
    newer = ~U[2026-08-19 10:00:01.000000Z]

    assert {:ok, [_company]} =
             TallyDevices.report_companies(
               device,
               [%{"name" => "Nila", "tally_guid" => "nila"}],
               newer
             )

    assert :ok = TallyDevices.mark_companies_closed(device.id, older)
    assert [_company] = TallyDevices.list_open_companies(org.id)

    assert :ok = TallyDevices.mark_companies_closed(device.id, newer)
    assert [] = TallyDevices.list_open_companies(org.id)
  end
end
