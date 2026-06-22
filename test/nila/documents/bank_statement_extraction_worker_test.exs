defmodule Nila.Documents.BankStatementExtractionWorkerTest do
  use Nila.DataCase

  alias Nila.Banking
  alias Nila.Documents
  alias Nila.Documents.BankStatementExtractionWorker
  alias Nila.Documents.Import
  alias Nila.Orgs

  setup do
    org =
      Orgs.create_org!(%{
        name: "Bank Worker Co",
        legal_name: "Bank Worker Company",
        gstin: "29ABCDE1234F1ZW"
      })

    %{org: org}
  end

  test "import enqueues the bank statement worker", %{org: org} do
    assert {:ok, document} =
             Import.import_bank_statement(%{
               org_id: org.id,
               filename: "statement.pdf",
               bytes: "%PDF statement"
             })

    assert document.document_type == "bank_statement"

    assert [%Oban.Job{worker: "Nila.Documents.BankStatementExtractionWorker"}] =
             Repo.all(Oban.Job)
  end

  test "worker writes an artifact and projects transaction rows", %{org: org} do
    assert {:ok, document} =
             Import.import_bank_statement(%{
               org_id: org.id,
               filename: "statement.pdf",
               bytes: "%PDF statement"
             })

    assert :ok =
             BankStatementExtractionWorker.perform(%Oban.Job{
               args: %{"document_id" => document.id}
             })

    document = Documents.get_document!(document.id)
    artifact = List.first(document.artifacts)

    assert document.status == "needs_review"
    assert document.extracted_at
    assert artifact.kind == "bank_statement_extraction"
    assert artifact.data["account"]["bank_name"] == "HDFC Bank"

    [account] = Banking.list_accounts(org.id)
    assert Banking.count_transactions(account.id) == 5
  end

  test "re-running the worker on the same document does not duplicate rows", %{org: org} do
    assert {:ok, document} =
             Import.import_bank_statement(%{
               org_id: org.id,
               filename: "statement.pdf",
               bytes: "%PDF statement"
             })

    assert :ok =
             BankStatementExtractionWorker.perform(%Oban.Job{
               args: %{"document_id" => document.id}
             })

    assert :ok =
             BankStatementExtractionWorker.perform(%Oban.Job{
               args: %{"document_id" => document.id}
             })

    [account] = Banking.list_accounts(org.id)
    assert Banking.count_transactions(account.id) == 5
  end
end
