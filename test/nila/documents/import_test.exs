defmodule Nila.Documents.ImportTest do
  use Nila.DataCase

  alias Nila.Accounts
  alias Nila.Documents
  alias Nila.Documents.Import
  alias Nila.Documents.PurchaseOrderExtractionWorker
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

  test "local path import decodes the path and stores a purchase order document", %{org: org} do
    dir = Path.join(System.tmp_dir!(), "nila-import-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "PO 4532258231_AP.pdf")
    File.write!(path, "%PDF fixture")

    assert {:ok, document} =
             Import.import_purchase_order_from_path(URI.encode(path),
               org_id: org.id
             )

    assert document.filename == "PO 4532258231_AP.pdf"
    assert document.document_type == "purchase_order"
    assert document.status == "uploaded"
    assert document.sha256
    assert {:ok, "%PDF fixture"} = Storage.get(document.storage_key)

    assert [%Oban.Job{worker: "Nila.Documents.PurchaseOrderExtractionWorker"}] =
             Repo.all(Oban.Job)
  end

  test "duplicate SHA-256 import is idempotent", %{org: org} do
    attrs = %{
      org_id: org.id,
      filename: "PO 4532258231_AP.pdf",
      bytes: "%PDF fixture"
    }

    assert {:ok, first} = Import.import_purchase_order(attrs)
    assert {:ok, second} = Import.import_purchase_order(attrs)

    assert first.id == second.id
    assert Repo.aggregate(Nila.Documents.Document, :count) == 1
  end

  test "generic import stores content type and keeps extension", %{org: org} do
    assert {:ok, document} =
             Import.import_document(%{
               org_id: org.id,
               filename: "po-photo.jpg",
               content_type: "image/jpeg",
               document_type: "purchase_order",
               bytes: "jpeg fixture"
             })

    assert document.filename == "po-photo.jpg"
    assert document.content_type == "image/jpeg"
    assert document.document_type == "purchase_order"
    assert String.ends_with?(document.storage_key, "/original.jpg")
    assert {:ok, "jpeg fixture"} = Storage.get(document.storage_key)
  end

  test "purchase order extraction stores a pending review artifact", %{org: org} do
    assert {:ok, document} =
             Import.import_purchase_order(%{
               org_id: org.id,
               filename: "PO 4532258231_AP.pdf",
               bytes: "%PDF fixture"
             })

    assert :ok =
             PurchaseOrderExtractionWorker.perform(%Oban.Job{
               args: %{"document_id" => document.id}
             })

    document = Documents.get_document!(document.id)
    artifact = List.first(document.artifacts)

    assert document.status == "needs_review"
    assert document.processing_started_at
    assert document.extracted_at
    assert artifact.kind == "purchase_order_extraction"
    assert artifact.status == "pending_review"
    assert artifact.data["data"]["po_number"] == "4532258231"
  end

  test "extraction failure only marks failed on the last attempt", %{org: org} do
    previous = Application.get_env(:nila, :po_extractor)
    Application.put_env(:nila, :po_extractor, Nila.FailingPoExtractor)
    on_exit(fn -> Application.put_env(:nila, :po_extractor, previous) end)

    assert {:ok, document} =
             Import.import_purchase_order(%{
               org_id: org.id,
               filename: "PO failure.pdf",
               bytes: "%PDF fixture"
             })

    assert {:error, :forced_extractor_error} =
             PurchaseOrderExtractionWorker.perform(%Oban.Job{
               args: %{"document_id" => document.id},
               attempt: 1,
               max_attempts: 3
             })

    document = Documents.get_document!(document.id)
    assert document.status == "processing"
    assert document.processing_started_at

    assert {:error, :forced_extractor_error} =
             PurchaseOrderExtractionWorker.perform(%Oban.Job{
               args: %{"document_id" => document.id},
               attempt: 3,
               max_attempts: 3
             })

    assert Documents.get_document!(document.id).status == "failed"
  end

  test "retry_extraction only retries failed documents", %{org: org} do
    assert {:ok, document} =
             Import.import_purchase_order(%{
               org_id: org.id,
               filename: "PO not failed.pdf",
               bytes: "%PDF fixture"
             })

    assert {:error, :not_failed} = Documents.retry_extraction(document)
  end

  test "retry_extraction resets status and enqueues a fresh worker", %{org: org} do
    assert {:ok, document} =
             Import.import_purchase_order(%{
               org_id: org.id,
               filename: "PO retry.pdf",
               bytes: "%PDF fixture"
             })

    {:ok, failed} =
      Documents.update_document(document, %{status: "failed", extracted_at: DateTime.utc_now()})

    assert {:ok, retried} = Documents.retry_extraction(failed)

    assert retried.status == "processing"
    assert retried.processing_started_at
    refute retried.extracted_at
    assert Repo.aggregate(Oban.Job, :count) == 2
  end

  test "approving a purchase-order extraction marks it approved without enqueuing a worker", %{
    org: org,
    user: user
  } do
    assert {:ok, document} =
             Import.import_purchase_order(%{
               org_id: org.id,
               filename: "PO 4532258231_AP.pdf",
               bytes: "%PDF fixture"
             })

    :ok =
      PurchaseOrderExtractionWorker.perform(%Oban.Job{
        args: %{"document_id" => document.id}
      })

    extraction =
      document.id
      |> Documents.get_document!()
      |> Map.fetch!(:artifacts)
      |> List.first()

    assert {:ok, approved} = Documents.approve_artifact(extraction, user.id)
    assert approved.status == "approved"
    assert Documents.get_document!(document.id).status == "approved"

    # Approving an artifact has no downstream side effect of its own — beyond the
    # extraction job enqueued at upload, it enqueues nothing extra.
    assert [%Oban.Job{worker: "Nila.Documents.PurchaseOrderExtractionWorker"}] =
             Repo.all(Oban.Job)
  end
end
