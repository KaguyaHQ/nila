defmodule Nila.TallyJobsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.TallyDevices
  alias Nila.TallyJobs

  test "a voucher job is claimed once and completed durably" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Office PC"})

    assert {:ok, job} =
             TallyJobs.enqueue_create_voucher(
               device,
               %{
                 "company" => "Nila",
                 "date" => "2026-08-01",
                 "voucher_type" => "Payment",
                 "debit_ledger" => "NILA Playground Customer",
                 "credit_ledger" => "Cash",
                 "amount" => "1.00",
                 "narration" => "Nila connector test"
               },
               job_key: "d45f7537-00d5-4463-9d70-f246257d88ef"
             )

    assert {:ok, claimed} = TallyJobs.claim_next(device.id)
    assert claimed.id == job.id
    assert claimed.status == "running"
    assert claimed.attempts == 1
    assert {:ok, nil} = TallyJobs.claim_next(device.id)

    assert {:ok, completed} =
             TallyJobs.complete(device.id, job.id, "succeeded", %{
               "created" => 1,
               "errors" => 0,
               "last_voucher_id" => 123
             })

    assert completed.status == "succeeded"
    assert completed.result["last_voucher_id"] == 123
    assert completed.completed_at
  end

  test "concurrent connector deliveries cannot claim the same logical job twice" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Office PC"})

    assert {:ok, job} =
             TallyJobs.enqueue_create_voucher(
               device,
               %{"company" => "Nila", "amount" => "1.00"},
               source_key: "sales-bills:race:voucher:INV-001"
             )

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          receive do
            :claim -> TallyJobs.claim_next(device.id)
          end
        end)
      end

    Enum.each(tasks, fn task ->
      Ecto.Adapters.SQL.Sandbox.allow(Nila.Repo, self(), task.pid)
    end)

    Enum.each(tasks, &send(&1.pid, :claim))

    results = Enum.map(tasks, &Task.await/1)

    assert Enum.count(results, &match?({:ok, %{id: id}} when id == job.id, &1)) == 1
    assert Enum.count(results, &match?({:ok, nil}, &1)) == 1
  end

  test "records an ambiguous Tally outcome without making it retryable" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Timeout PC"})

    assert {:ok, job} =
             TallyJobs.enqueue_create_voucher(device, %{
               "company" => "Nila",
               "date" => "2026-08-01",
               "voucher_type" => "Payment",
               "debit_ledger" => "NILA Playground Customer",
               "credit_ledger" => "Cash",
               "amount" => "1.00",
               "narration" => "Ambiguous request"
             })

    assert {:ok, _claimed} = TallyJobs.claim_next(device.id)

    assert {:ok, completed} =
             TallyJobs.complete(device.id, job.id, "indeterminate", %{
               "kind" => "Timeout",
               "message" => "Tally did not respond in time."
             })

    assert completed.status == "indeterminate"
    assert completed.error["kind"] == "Timeout"
    assert {:ok, nil} = TallyJobs.claim_next(device.id)
  end

  test "queues a company-scoped voucher batch idempotently by source" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [%{"name" => "Nila", "tally_guid" => "nila"}])

    xml = "<ENVELOPE><HEADER/><BODY/></ENVELOPE>"

    assert {:ok, first, :created} =
             TallyJobs.enqueue_import_vouchers(company, xml, 2,
               source_key: "gstr1:42:company:#{company.id}"
             )

    assert {:ok, repeated, :existing} =
             TallyJobs.enqueue_import_vouchers(company, xml, 2,
               source_key: "gstr1:42:company:#{company.id}"
             )

    assert repeated.id == first.id
    assert first.kind == "import_vouchers"
    assert first.payload["company"] == "Nila"
    assert first.payload["expected_count"] == 2
    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 1
  end

  test "marks an in-flight job indeterminate when its connector disconnects" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    assert {:ok, job} =
             TallyJobs.enqueue_create_voucher(device, %{
               "company" => "Nila",
               "amount" => "1.00"
             })

    assert {:ok, running} = TallyJobs.claim_next(device.id)
    assert running.id == job.id
    assert {:ok, 1} = TallyJobs.interrupt_running(device.id)

    interrupted = TallyJobs.get_job!(job.id)
    assert interrupted.status == "indeterminate"
    assert interrupted.error["kind"] == "ConnectorDisconnected"
    assert {:ok, nil} = TallyJobs.claim_next(device.id)
  end

  test "requeues an indeterminate voucher for read-only verification" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    assert {:ok, job} =
             TallyJobs.enqueue_create_voucher(
               device,
               %{"company" => "Nila"},
               source_key: "sales-bills:batch:voucher:INV-001"
             )

    assert {:ok, _running} = TallyJobs.claim_next(device.id)

    assert {:ok, _unknown} =
             TallyJobs.complete(device.id, job.id, "indeterminate", %{"kind" => "Disconnected"})

    assert {:ok, 1} =
             TallyJobs.verify_indeterminate_by_source_prefix(
               org.id,
               "sales-bills:batch:voucher:"
             )

    pending = TallyJobs.get_job!(job.id)
    assert pending.status == "pending"
    assert pending.payload["mode"] == "verify_only"
    assert is_nil(pending.error)
  end

  test "rechecks a successful voucher with its frozen payload in normal delivery mode" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    assert {:ok, job} =
             TallyJobs.enqueue_create_voucher(
               device,
               %{"company" => "Nila", "mode" => "verify_only"},
               source_key: "sales-bills:batch:voucher:INV-001"
             )

    assert {:ok, _running} = TallyJobs.claim_next(device.id)
    assert {:ok, _done} = TallyJobs.complete(device.id, job.id, "succeeded", %{"master_id" => 42})

    assert {:ok, 1} =
             TallyJobs.ensure_succeeded_by_source_prefix(
               org.id,
               "sales-bills:batch:voucher:"
             )

    pending = TallyJobs.get_job!(job.id)
    assert pending.status == "pending"
    refute Map.has_key?(pending.payload, "mode")
    assert is_nil(pending.result)
  end

  test "queues and retries each definite voucher failure independently" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [%{"name" => "Nila", "tally_guid" => "nila"}])

    insert_voucher_type(company, "Sales", "Manual")

    items = [
      %{
        source_id: "voucher-one",
        invoice_number: "INV-001",
        voucher_type: "Sales",
        xml: "<ENVELOPE><TALLYMESSAGE/></ENVELOPE>"
      },
      %{
        source_id: "voucher-two",
        invoice_number: "INV-002",
        voucher_type: "Sales",
        xml: "<ENVELOPE><TALLYMESSAGE/></ENVELOPE>"
      }
    ]

    assert {:ok, [{first, :created}, {second, :created}]} =
             TallyJobs.enqueue_vouchers(company, items, source_prefix: "gstr1:7:voucher:")

    assert first.payload["invoice_number"] == "INV-001"
    assert second.payload["invoice_number"] == "INV-002"
    assert is_nil(first.payload["party_ledger"])
    assert is_nil(second.payload["party_ledger"])

    assert {:ok, claimed} = TallyJobs.claim_next(device.id)
    assert claimed.id == first.id

    assert {:ok, failed} =
             TallyJobs.complete(device.id, first.id, "failed", %{"message" => "Ledger missing"})

    assert failed.status == "failed"

    assert {:ok, [{retried, :retried}, {same_second, :existing}]} =
             TallyJobs.enqueue_vouchers(company, items, source_prefix: "gstr1:7:voucher:")

    assert retried.id == first.id
    assert retried.status == "pending"
    assert retried.payload["xml"] == "<ENVELOPE><TALLYMESSAGE/></ENVELOPE>"
    assert is_binary(retried.payload_hash)
    assert same_second.id == second.id
    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 2
  end

  test "a regenerated correlation UUID does not change the frozen voucher payload" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [%{"name" => "Nila", "tally_guid" => "nila"}])

    insert_voucher_type(company, "Sales", "Manual")

    first_xml = correlated_voucher_xml("11111111-1111-4111-8111-111111111111", "100.00")

    first_item = %{
      source_id: "voucher-one",
      invoice_number: "INV-001",
      voucher_type: "Sales",
      xml: first_xml
    }

    assert {:ok, [{job, :created}]} =
             TallyJobs.enqueue_vouchers(company, [first_item],
               source_prefix: "gstr1:correlation:voucher:"
             )

    assert {:ok, _claimed} = TallyJobs.claim_next(device.id)
    assert {:ok, _failed} = TallyJobs.complete(device.id, job.id, "failed", %{"message" => "No"})

    regenerated = %{
      first_item
      | xml: correlated_voucher_xml("22222222-2222-4222-8222-222222222222", "100.00")
    }

    assert {:ok, [{retried, :retried}]} =
             TallyJobs.enqueue_vouchers(company, [regenerated],
               source_prefix: "gstr1:correlation:voucher:"
             )

    assert retried.id == job.id
    assert retried.payload["xml"] == first_xml
  end

  test "refuses to mutate a failed voucher payload under the same source key" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [%{"name" => "Nila", "tally_guid" => "nila"}])

    insert_voucher_type(company, "Sales", "Manual")

    item = %{
      source_id: "voucher-one",
      invoice_number: "INV-001",
      voucher_type: "Sales",
      xml: "<ENVELOPE><ORIGINAL/></ENVELOPE>"
    }

    assert {:ok, [{job, :created}]} =
             TallyJobs.enqueue_vouchers(company, [item], source_prefix: "gstr1:8:voucher:")

    assert {:ok, _claimed} = TallyJobs.claim_next(device.id)
    assert {:ok, _failed} = TallyJobs.complete(device.id, job.id, "failed", %{"message" => "No"})

    changed = %{item | xml: "<ENVELOPE><CHANGED/></ENVELOPE>"}

    assert {:error, :payload_changed} =
             TallyJobs.enqueue_vouchers(company, [changed], source_prefix: "gstr1:8:voucher:")

    persisted = TallyJobs.get_job!(job.id)
    assert persisted.status == "failed"
    assert persisted.payload["xml"] == item.xml
  end

  defp insert_voucher_type(company, name, numbering_method) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Nila.Repo.insert!(%Nila.TallyDevices.SyncedMaster{
      org_id: company.org_id,
      company_id: company.id,
      kind: "voucher_type",
      identity: "name:#{String.downcase(name)}",
      name: name,
      data: %{"numbering_method" => numbering_method},
      inserted_at: now,
      updated_at: now
    })
  end

  defp correlated_voucher_xml(correlation_id, amount) do
    """
    <ENVELOPE>
      <VOUCHER REMOTEID="#{correlation_id}">
        <GUID>#{correlation_id}</GUID>
        <AMOUNT>#{amount}</AMOUNT>
      </VOUCHER>
    </ENVELOPE>
    """
  end
end
