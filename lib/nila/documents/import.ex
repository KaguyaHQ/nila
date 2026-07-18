defmodule Nila.Documents.Import do
  @moduledoc """
  Imports source document files into Nila storage and document records, and
  enqueues the extraction worker for the document's type.
  """

  alias Nila.Documents
  alias Nila.Documents.BankStatementExtractionWorker
  alias Nila.Repo
  alias Nila.Storage

  def import_document(attrs) do
    org_id = Map.fetch!(attrs, :org_id)
    filename = Map.fetch!(attrs, :filename)
    bytes = Map.fetch!(attrs, :bytes)
    uploaded_by_id = Map.get(attrs, :uploaded_by_id)
    content_type = Map.get(attrs, :content_type, "application/octet-stream")
    document_type = Map.get(attrs, :document_type, "bank_statement")
    sha256 = sha256(bytes)
    storage_key = storage_key(org_id, sha256, filename, content_type)

    Repo.transact(fn ->
      with {:ok, document} <-
             (case get_by_sha(org_id, sha256) do
                {:error, :not_found} ->
                  {:ok, _stored} = Storage.put(storage_key, bytes, content_type: content_type)

                  Documents.create_document(%{
                    org_id: org_id,
                    uploaded_by_id: uploaded_by_id,
                    storage_key: storage_key,
                    filename: filename,
                    content_type: content_type,
                    byte_size: byte_size(bytes),
                    sha256: sha256,
                    document_type: document_type,
                    status: "uploaded"
                  })

                {:ok, document} ->
                  {:ok, document}
              end) do
        maybe_enqueue_extraction(document)
        {:ok, document}
      end
    end)
  end

  def import_bank_statement(attrs) do
    attrs
    |> Map.put(:document_type, "bank_statement")
    |> Map.put_new(:content_type, "application/pdf")
    |> import_document()
  end

  def import_bank_statement_from_path(path, opts) do
    org_id = Keyword.fetch!(opts, :org_id)
    uploaded_by_id = Keyword.get(opts, :uploaded_by_id)
    expanded_path = path |> URI.decode() |> Path.expand()

    with {:ok, bytes} <- File.read(expanded_path) do
      import_bank_statement(%{
        org_id: org_id,
        uploaded_by_id: uploaded_by_id,
        filename: Path.basename(expanded_path),
        content_type: "application/pdf",
        bytes: bytes
      })
    end
  end

  defp maybe_enqueue_extraction(%{document_type: "bank_statement", id: document_id}) do
    {:ok, _job} =
      %{document_id: document_id}
      |> BankStatementExtractionWorker.new()
      |> Oban.insert()
  end

  defp maybe_enqueue_extraction(_document), do: :ok

  defp get_by_sha(org_id, sha256) do
    Repo.fetch_by(Nila.Documents.Document, org_id: org_id, sha256: sha256)
  end

  defp storage_key(org_id, sha256, filename, content_type) do
    extension = filename_extension(filename) || content_type_extension(content_type) || ".bin"
    "orgs/#{org_id}/documents/#{sha256}/original#{extension}"
  end

  defp filename_extension(filename) do
    case Path.extname(filename) do
      "" -> nil
      extension -> extension
    end
  end

  defp content_type_extension("application/pdf"), do: ".pdf"
  defp content_type_extension("image/jpeg"), do: ".jpg"
  defp content_type_extension("image/png"), do: ".png"
  defp content_type_extension(_content_type), do: nil

  defp sha256(bytes) do
    :crypto.hash(:sha256, bytes)
    |> Base.encode16(case: :lower)
  end
end
