defmodule Nila.BankingTest do
  use Nila.DataCase, async: true
  use Oban.Testing, repo: Nila.Repo

  alias Nila.Banking
  alias Nila.Banking.StatementWorker
  alias Nila.Banking.Transaction
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
             Banking.configure_tally(context.org.id, statement.id, bank.identity)

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

  test "voucher override derives direction, including reversals, and preserves mapping",
       context do
    {:ok, statement} = statement_fixture(context)

    rows =
      for {withdrawal, deposit, type, ordinal} <- [
            {100, 0, "payment", 1},
            {0, 200, "receipt", 2},
            {-100, 0, "payment", 3},
            {0, -200, "receipt", 4}
          ] do
        Repo.insert!(%Transaction{
          org_id: context.org.id,
          statement_id: statement.id,
          identity: "transfer-#{ordinal}",
          ordinal: ordinal,
          date: ~D[2026-06-01],
          narration: "Transfer",
          withdrawal_paise: withdrawal,
          deposit_paise: deposit,
          balance_paise: 10_000,
          transaction_type: type,
          status: "ready",
          counter_ledger_identity: "ledger-#{ordinal}",
          counter_ledger_name: "Ledger #{ordinal}"
        })
      end

    ids = Enum.map(rows, & &1.id)

    assert {:ok, changed} =
             Banking.change_voucher_type(context.org.id, statement.id, ids, "contra")

    assert Enum.map(changed, & &1.transaction_type) ==
             ~w(contra_withdrawal contra_deposit contra_withdrawal contra_deposit)

    for {original, updated} <- Enum.zip(rows, changed) do
      assert updated.counter_ledger_identity == original.counter_ledger_identity
      assert updated.counter_ledger_name == original.counter_ledger_name
      assert updated.status == original.status
    end

    assert {:ok, restored} =
             Banking.change_voucher_type(context.org.id, statement.id, ids, "payment_receipt")

    assert Enum.map(restored, & &1.transaction_type) == ~w(payment receipt payment receipt)
  end

  test "voucher override rejects protected or foreign selections without partial changes",
       context do
    {:ok, statement} = statement_fixture(context)
    {:ok, other_statement} = statement_fixture(context, source_key: "other.pdf")
    %{org: other_org} = Nila.AccountsFixtures.user_with_org_fixture()

    rows =
      for {status, ordinal} <- Enum.with_index(~w(unassigned ignored queued posted verifying), 1) do
        Repo.insert!(%Transaction{
          org_id: context.org.id,
          statement_id: statement.id,
          identity: "row-#{ordinal}",
          ordinal: ordinal,
          date: ~D[2026-06-01],
          narration: "Transfer",
          deposit_paise: 100,
          balance_paise: 10_000,
          transaction_type: "receipt",
          status: status
        })
      end

    [editable | protected] = rows

    for row <- protected do
      assert {:error, :transactions_changed} =
               Banking.change_voucher_type(
                 context.org.id,
                 statement.id,
                 [editable.id, row.id],
                 "contra"
               )

      assert Repo.get!(Transaction, editable.id).transaction_type == "receipt"
    end

    assert {:error, :not_found} =
             Banking.change_voucher_type(other_org.id, statement.id, [editable.id], "contra")

    assert {:error, :transactions_changed} =
             Banking.change_voucher_type(
               context.org.id,
               other_statement.id,
               [editable.id],
               "contra"
             )

    assert {:error, :invalid_transactions} =
             Banking.change_voucher_type(context.org.id, statement.id, [editable.id], "journal")
  end

  test "normal ledger assignment preserves a Contra override", context do
    {:ok, statement} = statement_fixture(context)
    {:ok, _} = Storage.put(statement.source_key, "%PDF", content_type: "application/pdf")
    assert :ok = perform_job(StatementWorker, %{statement_id: statement.id})
    {:ok, statement} = Banking.get_statement(context.org.id, statement.id)
    [transaction] = statement.bank_transactions
    {:ok, company} = linked_company(context)
    bank = master(context.org.id, company.id, "bank", "HDFC Bank", "Bank Accounts")
    cash = master(context.org.id, company.id, "cash", "Cash", "Cash-in-Hand")
    assert {:ok, _} = Banking.configure_tally(context.org.id, statement.id, bank.identity)

    assert {:ok, [_]} =
             Banking.change_voucher_type(context.org.id, statement.id, [transaction.id], "contra")

    assert {:ok, [mapped]} =
             Banking.map_transactions(
               context.org.id,
               statement.id,
               [transaction.id],
               cash.identity
             )

    assert mapped.transaction_type == "contra_deposit"
    assert mapped.counter_ledger_identity == cash.identity
    assert mapped.status == "ready"
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

    context.client
    |> Ecto.Changeset.change(active_tally_company_id: company.id)
    |> Repo.update!()

    {:ok, company}
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
