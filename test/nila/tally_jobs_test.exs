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

    company = Nila.Repo.preload(company, :device)

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

  test "queues and retries each definite voucher failure independently" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [%{"name" => "Nila", "tally_guid" => "nila"}])

    company = Nila.Repo.preload(company, :device)

    items = [
      %{
        source_id: "voucher-one",
        invoice_number: "INV-001",
        xml: "<ENVELOPE><TALLYMESSAGE/></ENVELOPE>"
      },
      %{
        source_id: "voucher-two",
        invoice_number: "INV-002",
        xml: "<ENVELOPE><TALLYMESSAGE/></ENVELOPE>"
      }
    ]

    assert {:ok, [{first, :created}, {second, :created}]} =
             TallyJobs.enqueue_vouchers(company, items, source_prefix: "gstr1:7:voucher:")

    assert first.payload["invoice_number"] == "INV-001"
    assert second.payload["invoice_number"] == "INV-002"

    assert {:ok, claimed} = TallyJobs.claim_next(device.id)
    assert claimed.id == first.id

    assert {:ok, failed} =
             TallyJobs.complete(device.id, first.id, "failed", %{"message" => "Ledger missing"})

    assert failed.status == "failed"

    retry_items = put_in(items, [Access.at(0), :xml], "<ENVELOPE><UPDATED/></ENVELOPE>")

    assert {:ok, [{retried, :retried}, {same_second, :existing}]} =
             TallyJobs.enqueue_vouchers(company, retry_items, source_prefix: "gstr1:7:voucher:")

    assert retried.id == first.id
    assert retried.status == "pending"
    assert retried.payload["xml"] == "<ENVELOPE><UPDATED/></ENVELOPE>"
    assert same_second.id == second.id
    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 2
  end
end
