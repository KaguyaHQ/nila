defmodule Nila.TallyDevicesPairingTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Accounts.Scope
  alias Nila.Repo
  alias Nila.TallyDevices
  alias Nila.TallyDevices.{Device, Pairing}

  @now ~U[2026-08-19 08:00:00.000000Z]

  test "stores only hashes of independent approval and device codes" do
    assert {:ok, started} =
             TallyDevices.create_pairing(
               %{device_name: "Accounts PC", connector_version: "0.1.0"},
               @now
             )

    pairing = Repo.get!(Pairing, started.pairing.id)
    refute pairing.device_code_hash == started.device_code
    refute pairing.approval_code_hash == started.approval_code
    refute pairing.device_code_hash == pairing.approval_code_hash
    assert pairing.device_name == "Accounts PC"
    assert pairing.connector_version == "0.1.0"
  end

  test "pending exchange creates no device and codes cannot cross domains" do
    {:ok, started} = TallyDevices.create_pairing(%{device_name: "Accounts PC"}, @now)

    assert {:error, :pending} = TallyDevices.exchange_pairing(started.device_code, @now)

    assert {:error, :not_found} =
             TallyDevices.get_pairing_for_approval(started.device_code, @now)

    assert {:error, :not_found} = TallyDevices.exchange_pairing(started.approval_code, @now)
    assert Repo.aggregate(Device, :count) == 0
  end

  test "approval and exchange create exactly one durable device and exchange is idempotent" do
    %{user: user, org: org} = user_with_org_fixture()
    scope = Scope.for_user(user)
    {:ok, started} = TallyDevices.create_pairing(%{device_name: "Front desk PC"}, @now)

    assert {:ok, approved} =
             TallyDevices.approve_pairing(started.approval_code, scope, @now)

    assert approved.org_id == org.id
    assert approved.approved_by_user_id == user.id

    assert {:ok, first} = TallyDevices.exchange_pairing(started.device_code, @now)
    assert first.token == started.device_code
    assert first.device.org_id == org.id
    assert TallyDevices.authenticate_device(first.token).id == first.device.id

    assert {:ok, repeated} = TallyDevices.exchange_pairing(started.device_code, @now)
    assert repeated.device.id == first.device.id
    assert repeated.token == started.device_code
    assert Repo.aggregate(Device, :count) == 1
  end

  test "approval replay cannot rebind a pairing to another organization" do
    first = user_with_org_fixture()
    second = user_with_org_fixture()
    {:ok, started} = TallyDevices.create_pairing(%{device_name: "Shared PC"}, @now)

    assert {:ok, approved} =
             TallyDevices.approve_pairing(started.approval_code, Scope.for_user(first.user), @now)

    assert approved.org_id == first.org.id

    assert {:error, :already_approved} =
             TallyDevices.approve_pairing(
               started.approval_code,
               Scope.for_user(second.user),
               @now
             )

    assert Repo.reload!(approved).org_id == first.org.id
  end

  test "an exchanged pairing does not resurrect a revoked device" do
    %{user: user} = user_with_org_fixture()
    {:ok, started} = TallyDevices.create_pairing(%{device_name: "Revoked PC"}, @now)

    assert {:ok, _pairing} =
             TallyDevices.approve_pairing(started.approval_code, Scope.for_user(user), @now)

    assert {:ok, %{device: device}} = TallyDevices.exchange_pairing(started.device_code, @now)
    assert {:ok, _device} = TallyDevices.revoke_device(device, @now)

    assert {:error, :inactive_device} =
             TallyDevices.exchange_pairing(started.device_code, @now)
  end

  test "expired pairings cannot be approved or exchanged" do
    %{user: user} = user_with_org_fixture()
    {:ok, started} = TallyDevices.create_pairing(%{device_name: "Expired PC"}, @now)
    expired_at = DateTime.add(@now, 601, :second)

    assert {:error, :expired} =
             TallyDevices.approve_pairing(
               started.approval_code,
               Scope.for_user(user),
               expired_at
             )

    assert {:error, :expired} = TallyDevices.exchange_pairing(started.device_code, expired_at)
  end
end
