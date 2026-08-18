defmodule Nila.BankingTest do
  use Nila.DataCase, async: true
  use Oban.Testing, repo: Nila.Repo

  alias Nila.Banking
  alias Nila.Banking.StatementWorker
  alias Nila.Clients
  alias Nila.Storage

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
    assert ready.source_credentials == nil
    assert ready.account_number_masked == "•••• 4587"
    assert ready.transaction_count == 1
    assert ready.opening_balance_paise == 10_000
    assert ready.closing_balance_paise == 12_500
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
        bank_code: "hdfc",
        bank_name: "HDFC Bank",
        bank_ledger_name: "HDFC Bank",
        source_key: "orgs/#{context.org.id}/bank-statements/test/original.pdf",
        original_filename: "statement.pdf"
      })
    )
  end
end
