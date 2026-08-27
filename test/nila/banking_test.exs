defmodule Nila.BankingTest do
  use Nila.DataCase, async: true
  use Oban.Testing, repo: Nila.Repo

  alias Nila.Banking
  alias Nila.Banking.StatementWorker
  alias Nila.Clients
  alias Nila.Repo
  alias Nila.Storage
  alias Nila.TallyDevices
  alias Nila.TallyDevices.SyncedMaster
  alias Nila.TallyJobs

  setup do
    %{user: user, org: org} = Nila.AccountsFixtures.user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})
    %{user: user, org: org, client: client}
  end

  test "worker stores the structured artifact and erases the PDF password", context do
    {:ok, statement} =
      statement_fixture(context, source_credentials: %{"password" => "temporary"})

    {:ok, _stored} =
      Storage.put(statement.source_key, "%PDF-1.5 text", content_type: "application/pdf")

    assert :ok = perform_job(StatementWorker, %{statement_id: statement.id})

    assert {:ok, ready} = Banking.get_statement(context.org.id, statement.id)
    assert ready.status == "ready"
    assert ready.bank_code == "hdfc"
    assert ready.bank_ledger_name == nil
    assert ready.source_credentials == nil
    assert ready.account_number_masked == "•••• 4587"
    assert ready.transaction_count == 1
    assert ready.opening_balance_paise == 10_000
    assert ready.closing_balance_paise == 12_500
    assert [transaction] = ready.bank_transactions
    assert transaction.identity == "stub-1"
    assert transaction.transaction_type == "receipt"
    assert transaction.status == "unassigned"
  end

  test "maps a transaction to synced ledgers and queues one durable Tally job", context do
    {:ok, statement} = statement_fixture(context)
    {:ok, _stored} = Storage.put(statement.source_key, "%PDF", content_type: "application/pdf")
    assert :ok = perform_job(StatementWorker, %{statement_id: statement.id})
    {:ok, statement} = Banking.get_statement(context.org.id, statement.id)

    {:ok, company} = linked_company(context)
    bank = master(context.org.id, company.id, "bank", "HDFC Bank", "Bank Accounts")
    charges = master(context.org.id, company.id, "charges", "Bank Charges", "Indirect Expenses")

    assert {:ok, configured} =
             Banking.configure_tally(context.org.id, statement.id, company.id, bank.identity)

    assert configured.tally_company_id == company.id
    assert configured.bank_ledger_name == "HDFC Bank"

    [transaction] = statement.bank_transactions

    assert {:ok, [mapped]} =
             Banking.map_transactions(
               context.org.id,
               statement.id,
               [transaction.id],
               charges.identity
             )

    assert mapped.status == "ready"
    assert mapped.counter_ledger_name == "Bank Charges"

    assert {:ok, [queued]} =
             Banking.enqueue_transactions(context.org.id, statement.id, [transaction.id])

    assert queued.status == "queued"
    job = TallyJobs.get_job!(queued.tally_job_id)
    assert job.source_key == "bank:#{statement.id}:transaction:stub-1"
    assert job.payload["company"] == company.name
    assert job.payload["voucher_number_mode"] == "tally"
    assert job.payload["xml"] =~ "<LEDGERNAME>Bank Charges</LEDGERNAME>"
    assert job.payload["xml"] =~ "<VOUCHERTYPENAME>Receipt</VOUCHERTYPENAME>"
    refute job.payload["xml"] =~ "<VOUCHERNUMBER>"
    assert job.payload["xml"] =~ "<REMOTEALTGUID>"
    refute job.payload["xml"] =~ "REMOTEID="
    refute job.payload["xml"] =~ "<REFERENCE>"

    assert {:ok, claimed} = TallyJobs.claim_next(company.device_id)

    assert {:ok, _completed} =
             TallyJobs.complete(company.device_id, claimed.id, "succeeded", %{
               "master_id" => 321,
               "tally_guid" => "tally-bank-guid",
               "remote_alt_guid" => "d852c969-e235-8279-8a28-6604139d9010",
               "voucher_number" => "87"
             })

    assert {:ok, refreshed} = Banking.get_statement(context.org.id, statement.id)
    assert [posted] = refreshed.bank_transactions
    assert posted.status == "posted"
    assert posted.tally_master_id == 321
    assert posted.tally_guid == "tally-bank-guid"
  end

  test "failed extraction records an actionable error and erases the password", context do
    {:ok, statement} =
      statement_fixture(context, source_credentials: %{"password" => "temporary"})

    {:ok, _stored} = Storage.put(statement.source_key, "fail", content_type: "application/pdf")

    assert {:error, :not_text_pdf} = perform_job(StatementWorker, %{statement_id: statement.id})

    assert {:ok, failed} = Banking.get_statement(context.org.id, statement.id)
    assert failed.status == "failed"
    assert failed.source_credentials == nil
    assert failed.error =~ "bank-generated PDF"
  end

  test "rejects an exact duplicate statement for the same client", context do
    {:ok, first} = statement_fixture(context, source_key: "statements/first.pdf")
    {:ok, second} = statement_fixture(context, source_key: "statements/second.pdf")
    {:ok, _} = Storage.put(first.source_key, "same-pdf", content_type: "application/pdf")
    {:ok, _} = Storage.put(second.source_key, "same-pdf", content_type: "application/pdf")

    assert :ok = perform_job(StatementWorker, %{statement_id: first.id})

    assert {:error, :duplicate_statement} =
             perform_job(StatementWorker, %{statement_id: second.id})

    assert {:ok, duplicate} = Banking.get_statement(context.org.id, second.id)
    assert duplicate.status == "failed"
    assert duplicate.error =~ "already brought into Nila"
  end

  test "backfills durable rows when an older ready statement is opened", context do
    {:ok, statement} = statement_fixture(context)

    legacy_row = %{
      "id" => "legacy-1",
      "ordinal" => 1,
      "date" => "2026-06-01",
      "narration" => "Legacy row",
      "reference" => nil,
      "withdrawal_paise" => 100,
      "deposit_paise" => 0,
      "balance_paise" => 9_900
    }

    statement
    |> Ecto.Changeset.change(status: "ready", transactions: [legacy_row], transaction_count: 1)
    |> Repo.update!()

    assert Banking.list_transactions(context.org.id, statement.id) == []
    assert {:ok, opened} = Banking.get_statement(context.org.id, statement.id)
    assert [transaction] = opened.bank_transactions
    assert transaction.identity == "legacy-1"
  end

  test "statement reads are tenant scoped", context do
    {:ok, statement} = statement_fixture(context)
    %{org: other_org} = Nila.AccountsFixtures.user_with_org_fixture()

    assert {:ok, _statement} = Banking.get_statement(context.org.id, statement.id)
    assert {:error, :not_found} = Banking.get_statement(other_org.id, statement.id)
  end

  defp statement_fixture(context, overrides \\ []) do
    Banking.record_statement(
      %{
        org_id: context.org.id,
        client_id: context.client.id,
        brought_in_by_id: context.user.id
      },
      overrides
      |> Enum.into(%{
        source_key: "orgs/#{context.org.id}/bank-statements/test/original.pdf",
        original_filename: "statement.pdf"
      })
    )
  end

  defp linked_company(context) do
    {:ok, device, _token} = TallyDevices.create_device(context.org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{"name" => context.client.name, "tally_guid" => "company-breeze"}
      ])

    company = company |> Ecto.Changeset.change(client_id: context.client.id) |> Repo.update!()
    {:ok, Repo.preload(company, :device)}
  end

  defp master(org_id, company_id, identity, name, parent) do
    %SyncedMaster{
      org_id: org_id,
      company_id: company_id,
      kind: "ledger",
      identity: identity,
      name: name,
      data: %{"parent" => parent}
    }
    |> Repo.insert!()
  end
end
