defmodule NilaWeb.TallyDeviceSocketTest do
  use NilaWeb.ChannelCase, async: false

  alias Nila.{TallyDevices, TallyJobs}
  alias NilaWeb.{Presence, TallySocket}

  test "authenticates, joins only its own topic, and appears in org presence" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, token} = TallyDevices.create_device(org, %{name: "Office PC"})

    assert {:ok, socket} = connect(TallySocket, %{}, connect_info: %{auth_token: token})

    assert {:ok, reply, joined_socket} =
             subscribe_and_join(
               socket,
               NilaWeb.TallyDeviceChannel,
               "tally_device:#{device.id}",
               %{
                 "connector_version" => "0.1.0",
                 "companies" => [
                   %{
                     "name" => "Nila",
                     "tally_guid" => "company-nila",
                     "gstin" => "33AEWPH4158J1Z3"
                   }
                 ]
               }
             )

    assert reply == %{device_id: device.id, org_id: org.id}

    assert %{metas: [meta]} =
             Presence.get_by_key("tally_devices:#{org.id}", Integer.to_string(device.id))

    assert meta.device_id == device.id
    assert meta.connector_version == "0.1.0"

    ref = push(joined_socket, "ping", %{})
    assert_reply ref, :ok, %{online: true}

    refreshed = Nila.Repo.reload!(device)
    assert refreshed.last_connected_at

    assert [%{name: "Nila", tally_guid: "company-nila", gstin: "33AEWPH4158J1Z3"}] =
             TallyDevices.list_open_companies(org.id)

    NilaWeb.Endpoint.subscribe("tally_devices:#{org.id}")
    Process.unlink(joined_socket.channel_pid)
    channel_ref = Process.monitor(joined_socket.channel_pid)
    leave(joined_socket)
    assert_receive {:DOWN, ^channel_ref, :process, _pid, {:shutdown, :left}}

    assert_receive %Phoenix.Socket.Broadcast{
      event: "presence_diff",
      payload: %{leaves: leaves}
    }

    assert Map.has_key?(leaves, Integer.to_string(device.id))

    assert Presence.get_by_key(
             "tally_devices:#{org.id}",
             Integer.to_string(device.id)
           ) == []

    assert TallyDevices.list_open_companies(org.id) == []
  end

  test "rejects invalid and revoked credentials" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, token} = TallyDevices.create_device(org, %{name: "Revoked PC"})

    assert :error = connect(TallySocket, %{}, connect_info: %{auth_token: "invalid"})
    assert {:ok, _device} = TallyDevices.revoke_device(device)
    assert :error = connect(TallySocket, %{}, connect_info: %{auth_token: token})
  end

  test "revocation broadcasts a transport disconnect and closes the join race" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, token} = TallyDevices.create_device(org, %{name: "Race PC"})
    assert {:ok, socket} = connect(TallySocket, %{}, connect_info: %{auth_token: token})

    NilaWeb.Endpoint.subscribe("tally_device_socket:#{device.id}")
    assert {:ok, _revoked} = TallyDevices.revoke_device(device)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "tally_device_socket:" <> _,
      event: "disconnect"
    }

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(
               socket,
               NilaWeb.TallyDeviceChannel,
               "tally_device:#{device.id}",
               %{}
             )
  end

  test "an authenticated device cannot join another device topic" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, token} = TallyDevices.create_device(org, %{name: "First PC"})
    {:ok, other, _other_token} = TallyDevices.create_device(org, %{name: "Second PC"})
    assert {:ok, socket} = connect(TallySocket, %{}, connect_info: %{auth_token: token})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(
               socket,
               NilaWeb.TallyDeviceChannel,
               "tally_device:#{other.id}",
               %{}
             )

    refute device.id == other.id
  end

  test "delivers one durable voucher job and records its structured result" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, token} = TallyDevices.create_device(org, %{name: "Job PC"})

    assert {:ok, job} =
             TallyJobs.enqueue_create_voucher(device, %{
               "company" => "Nila",
               "date" => "2026-08-01",
               "voucher_type" => "Payment",
               "debit_ledger" => "NILA Playground Customer",
               "credit_ledger" => "Cash",
               "amount" => "1.00",
               "narration" => "Nila connector test"
             })

    assert {:ok, socket} = connect(TallySocket, %{}, connect_info: %{auth_token: token})

    assert {:ok, _reply, joined_socket} =
             subscribe_and_join(
               socket,
               NilaWeb.TallyDeviceChannel,
               "tally_device:#{device.id}",
               %{}
             )

    assert_push "job", %{
      job_id: job_id,
      job_key: job_key,
      kind: "create_voucher",
      payload: %{"company" => "Nila"}
    }

    assert job_id == job.id
    assert job_key == job.job_key

    ref =
      push(joined_socket, "job_result", %{
        "job_id" => job.id,
        "status" => "succeeded",
        "details" => %{"created" => 1, "errors" => 0, "last_voucher_id" => 321}
      })

    assert_reply ref, :ok
    assert TallyJobs.get_job!(job.id).status == "succeeded"
    assert TallyJobs.get_job!(job.id).result["last_voucher_id"] == 321
  end

  test "does not deliver a second job until the first result is acknowledged" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, token} = TallyDevices.create_device(org, %{name: "Serial Job PC"})

    payload = %{
      "company" => "Nila",
      "date" => "2026-08-19",
      "voucher_type" => "Payment",
      "debit_ledger" => "NILA Playground Customer",
      "credit_ledger" => "Cash",
      "amount" => "1.00",
      "narration" => "Serial delivery test"
    }

    assert {:ok, first} = TallyJobs.enqueue_create_voucher(device, payload)
    assert {:ok, second} = TallyJobs.enqueue_create_voucher(device, payload)
    assert {:ok, socket} = connect(TallySocket, %{}, connect_info: %{auth_token: token})

    assert {:ok, _reply, joined_socket} =
             subscribe_and_join(
               socket,
               NilaWeb.TallyDeviceChannel,
               "tally_device:#{device.id}",
               %{}
             )

    assert_push "job", %{job_id: first_id}
    assert first_id == first.id
    refute_push "job", _payload, 100
    assert TallyJobs.get_job!(second.id).status == "pending"

    ref =
      push(joined_socket, "job_result", %{
        "job_id" => first.id,
        "status" => "failed",
        "details" => %{"kind" => "ApplicationError", "message" => "Rejected"}
      })

    assert_reply ref, :ok
    assert_push "job", %{job_id: second_id}
    assert second_id == second.id
  end

  test "the endpoint enables Phoenix transport token extraction" do
    assert {"/connector", TallySocket, options} =
             Enum.find(NilaWeb.Endpoint.__sockets__(), fn {path, _socket, _options} ->
               path == "/connector"
             end)

    assert options[:auth_token] == true
    assert options[:longpoll] == false
  end
end
