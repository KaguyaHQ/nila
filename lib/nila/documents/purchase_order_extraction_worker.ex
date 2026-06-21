defmodule Nila.Documents.PurchaseOrderExtractionWorker do
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias Nila.Documents
  alias Nila.Storage

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => document_id}} = job) do
    started_at = System.monotonic_time()
    document = Documents.get_document!(document_id)

    try do
      do_perform(document, job, started_at)
    rescue
      exception ->
        handle_failure(document, job, Exception.format(:error, exception, __STACKTRACE__))
        reraise exception, __STACKTRACE__
    end
  end

  defp do_perform(document, job, started_at) do
    with {:ok, document} <-
           timed("po_extract.mark_processing", fn -> Documents.mark_processing(document) end,
             document_id: document.id,
             filename: document.filename
           ),
         :ok <-
           Documents.broadcast_progress(document, {:po_progress, document.id, :sent_to_reader}),
         {:ok, bytes} <-
           timed("po_extract.storage_get", fn -> Storage.get(document.storage_key) end,
             document_id: document.id,
             filename: document.filename,
             byte_size: document.byte_size
           ),
         {:ok, extraction} <-
           timed(
             "po_extract.extractor",
             fn ->
               extractor().extract(bytes,
                 filename: document.filename,
                 on_progress: fn stage ->
                   Documents.broadcast_progress(document, {:po_progress, document.id, stage})
                 end
               )
             end,
             document_id: document.id,
             filename: document.filename,
             extractor: inspect(extractor())
           ),
         :ok <- Documents.broadcast_progress(document, {:po_progress, document.id, :checking}),
         {:ok, _artifact} <-
           timed(
             "po_extract.artifact_write",
             fn ->
               Documents.create_or_update_artifact(%{
                 document_id: document.id,
                 kind: "purchase_order_extraction",
                 version: 1,
                 data: extraction,
                 status: "pending_review"
               })
             end,
             document_id: document.id,
             filename: document.filename
           ),
         {:ok, _document} <-
           timed(
             "po_extract.document_update",
             fn ->
               Documents.update_document(document, %{
                 status: "needs_review",
                 extracted_at: DateTime.utc_now()
               })
             end,
             document_id: document.id,
             filename: document.filename
           ),
         :ok <- Documents.broadcast_progress(document, {:po_done, document.id}) do
      Logger.info(
        "po_extract.complete document_id=#{document.id} filename=#{inspect(document.filename)} duration_ms=#{elapsed_ms(started_at)}"
      )

      :ok
    else
      {:error, reason} -> handle_failure(document, job, reason)
    end
  end

  defp handle_failure(document, job, reason) do
    Logger.error(
      "po_extract.failed document_id=#{document.id} filename=#{inspect(document.filename)} attempt=#{attempt(job)} max_attempts=#{max_attempts(job)} reason=#{inspect(reason)}"
    )

    if last_attempt?(job) do
      {:ok, failed_document} = Documents.mark_failed(document)
      Documents.broadcast_progress(failed_document, {:po_failed, failed_document.id, reason})
    end

    {:error, reason}
  end

  defp last_attempt?(job), do: attempt(job) >= max_attempts(job)
  defp attempt(%{attempt: attempt}) when is_integer(attempt) and attempt > 0, do: attempt
  defp attempt(_job), do: 1

  defp max_attempts(%{max_attempts: max_attempts})
       when is_integer(max_attempts) and max_attempts > 0, do: max_attempts

  defp max_attempts(_job), do: 3

  defp extractor do
    Application.get_env(:nila, :po_extractor, Nila.Documents.Extractor.Stub)
  end

  defp timed(label, fun, metadata) do
    started_at = System.monotonic_time()
    result = fun.()

    Logger.info(
      "#{label} #{format_metadata(metadata)} duration_ms=#{elapsed_ms(started_at)} result=#{result_tag(result)}"
    )

    result
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp result_tag({:ok, _}), do: "ok"
  defp result_tag(:ok), do: "ok"
  defp result_tag({:error, reason}), do: "error:#{inspect(reason)}"
  defp result_tag(other), do: inspect(other)

  defp format_metadata(metadata) do
    metadata
    |> Enum.map(fn {key, value} -> "#{key}=#{inspect(value)}" end)
    |> Enum.join(" ")
  end
end
