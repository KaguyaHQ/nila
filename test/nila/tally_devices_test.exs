defmodule Nila.TallyDevicesTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.TallyDevices
  alias Nila.Clients

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

  test "stores a valid company GSTIN and links the sole exact client match despite a different name" do
    %{org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    assert {:ok, [company]} =
             TallyDevices.report_companies(device, [
               %{
                 "name" => "Broozetech",
                 "tally_guid" => "company-breeze",
                 "gstin" => "33aewph4158j1z3"
               }
             ])

    assert company.gstin == "33AEWPH4158J1Z3"
    assert company.client_id == client.id
  end

  test "does not automatically link an invalid reported GSTIN" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    assert {:ok, [company]} =
             TallyDevices.report_companies(device, [
               %{"name" => "Broken GST", "tally_guid" => "broken", "gstin" => "not-a-gstin"}
             ])

    assert is_nil(company.gstin)
    assert is_nil(company.client_id)
  end

  test "a linked Tally company fills a blank client GSTIN without overwriting one" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    assert {:ok, [company]} =
             TallyDevices.report_companies(device, [
               %{"name" => "Caltech", "tally_guid" => "company-caltech"}
             ])

    assert {:ok, client} = TallyDevices.ensure_company_client(org.id, company.id)
    assert is_nil(client.gstin)

    assert {:ok, [reported]} =
             TallyDevices.report_companies(device, [
               %{
                 "name" => "Caltech",
                 "tally_guid" => "company-caltech",
                 "gstin" => "33BPBPK1081A1ZO"
               }
             ])

    assert reported.client_id == client.id
    assert Nila.Repo.get!(Nila.Clients.Client, client.id).gstin == "33BPBPK1081A1ZO"

    assert {:ok, [_reported]} =
             TallyDevices.report_companies(device, [
               %{
                 "name" => "Caltech",
                 "tally_guid" => "company-caltech",
                 "gstin" => "33AEWPH4158J1Z3"
               }
             ])

    assert Nila.Repo.get!(Nila.Clients.Client, client.id).gstin == "33BPBPK1081A1ZO"
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

  test "imports selected Tally companies as clients and reuses an existing name" do
    %{org: org} = user_with_org_fixture()

    {:ok, existing} =
      Clients.create_client(%{org_id: org.id, name: "Existing Books", type: "company"})

    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [existing_company, new_company, ignored_company]} =
      TallyDevices.report_companies(device, [
        %{"name" => "Existing Books", "tally_guid" => "existing"},
        %{"name" => "New Client", "tally_guid" => "new"},
        %{"name" => "Demo Company", "tally_guid" => "demo"}
      ])

    assert {:ok, result} =
             TallyDevices.import_companies_as_clients(org.id, [
               existing_company.id,
               new_company.id
             ])

    assert result.created == 1
    assert result.linked == 1
    assert Enum.map(result.clients, & &1.name) == ["Existing Books", "New Client"]

    existing_company_id = existing_company.id
    assert [%{id: ^existing_company_id}] = TallyDevices.list_open_companies(org.id, existing.id)

    assert Enum.map(TallyDevices.list_importable_companies(org.id), & &1.id) == [
             ignored_company.id
           ]

    assert length(Clients.list_clients(org.id)) == 2
  end

  test "does not import another organization's discovered company" do
    %{org: org} = user_with_org_fixture()
    %{org: other_org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(other_org, %{name: "Other PC"})
    {:ok, [company]} = TallyDevices.report_companies(device, [%{"name" => "Other Books"}])

    assert {:error, :companies_changed} =
             TallyDevices.import_companies_as_clients(org.id, [company.id])

    assert Clients.list_clients(org.id) == []
  end
end
