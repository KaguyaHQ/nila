defmodule Nila.Documents.ImportTest do
  use Nila.DataCase

  alias Nila.Accounts
  alias Nila.Documents
  alias Nila.Documents.Import
  alias Nila.Orgs
  alias Nila.Repo
  alias Nila.Storage

  setup do
    org =
      Orgs.create_org!(%{
        name: "Import Test Co",
        legal_name: "Import Test Company",
        gstin: "29ABCDE1234F1ZW"
      })

    user =
      Accounts.create_user!(%{
        name: "Reviewer",
        email: "reviewer-#{System.unique_integer([:positive])}@example.com"
      })

    %{org: org, user: user}
  end

  test "local path import decodes the path and stores a document", %{org: org} do
    dir = Path.join(System.tmp_dir!(), "nila-import-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "HDFC statement May.pdf")
    File.write!(path, "%PDF fixture")

    assert {:ok, document} =
             Import.import_bank_statement_from_path(URI.encode(path), org_id: org.id)

    assert document.filename == "HDFC statement May.pdf"
    assert document.document_type == "bank_statement"
    assert document.status == "uploaded"
    assert document.sha256
    assert {:ok, "%PDF fixture"} = Storage.get(document.storage_key)

    assert [%Oban.Job{worker: "Nila.Documents.BankStatementExtractionWorker"}] =
             Repo.all(Oban.Job)
  end

  test "duplicate SHA-256 import is idempotent", %{org: org} do
    attrs = %{
      org_id: org.id,
      filename: "HDFC statement May.pdf",
      bytes: "%PDF fixture"
    }

    assert {:ok, first} = Import.import_bank_statement(attrs)
    assert {:ok, second} = Import.import_bank_statement(attrs)

    assert first.id == second.id
    assert Repo.aggregate(Nila.Documents.Document, :count) == 1
  end

  test "generic import stores content type and keeps extension", %{org: org} do
    assert {:ok, document} =
             Import.import_document(%{
               org_id: org.id,
               filename: "statement-photo.jpg",
               content_type: "image/jpeg",
               document_type: "bank_statement",
               bytes: "jpeg fixture"
             })

    assert document.filename == "statement-photo.jpg"
    assert document.content_type == "image/jpeg"
    assert document.document_type == "bank_statement"
    assert String.ends_with?(document.storage_key, "/original.jpg")
    assert {:ok, "jpeg fixture"} = Storage.get(document.storage_key)
  end

  test "approving an extraction artifact marks document and artifact approved", %{
    org: org,
    user: user
  } do
    assert {:ok, document} =
             Import.import_bank_statement(%{
               org_id: org.id,
               filename: "HDFC statement May.pdf",
               bytes: "%PDF fixture"
             })

    assert {:ok, artifact} =
             Documents.create_or_update_artifact(%{
               document_id: document.id,
               kind: "bank_statement_extraction",
               version: 1,
               data: %{"account" => %{"bank_name" => "HDFC"}},
               status: "pending_review"
             })

    assert {:ok, approved} = Documents.approve_artifact(artifact, user.id)
    assert approved.status == "approved"
    assert Documents.get_document!(document.id).status == "approved"
  end

  test "rejecting an extraction artifact marks document and artifact rejected", %{
    org: org,
    user: user
  } do
    assert {:ok, document} =
             Import.import_bank_statement(%{
               org_id: org.id,
               filename: "HDFC statement May.pdf",
               bytes: "%PDF fixture"
             })

    assert {:ok, artifact} =
             Documents.create_or_update_artifact(%{
               document_id: document.id,
               kind: "bank_statement_extraction",
               version: 1,
               data: %{"account" => %{"bank_name" => "HDFC"}},
               status: "pending_review"
             })

    assert {:ok, rejected} = Documents.reject_artifact(artifact, user.id)
    assert rejected.status == "rejected"
    assert Documents.get_document!(document.id).status == "rejected"
  end
end
