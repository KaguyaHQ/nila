defmodule Nila.Documents.BankStatementExtractionWorker do
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias Nila.Banking
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
           timed("bank_extract.mark_processing", fn -> Documents.mark_processing(document) end,
             document_id: document.id,
             filename: document.filename
           ),
         :ok <-
           Banking.broadcast_progress(
             document.org_id,
             {:bank_progress, document.id, :sent_to_reader}
           ),
         {:ok, bytes} <-
           timed("bank_extract.storage_get", fn -> Storage.get(document.storage_key) end,
             document_id: document.id,
             filename: document.filename,
             byte_size: document.byte_size
           ),
         {:ok, extraction} <-
           timed(
             "bank_extract.extractor",
             fn ->
               extractor().extract(bytes,
                 filename: document.filename,
                 on_progress: fn stage ->
                   Banking.broadcast_progress(
                     document.org_id,
                     {:bank_progress, document.id, stage}
                   )
                 end
               )
             end,
             document_id: document.id,
             filename: document.filename,
             extractor: inspect(extractor())
           ),
         :ok <-
           Banking.broadcast_progress(document.org_id, {:bank_progress, document.id, :projecting}),
         {:ok, _artifact} <-
           timed(
             "bank_extract.artifact_write",
             fn ->
               Documents.create_or_update_artifact(%{
                 document_id: document.id,
                 kind: "bank_statement_extraction",
                 version: 1,
                 data: extraction,
                 status: "pending_review"
               })
             end,
             document_id: document.id,
             filename: document.filename
           ),
         {:ok, account} <- upsert_account(document, extraction),
         {:ok, count} <-
           timed(
             "bank_extract.project_rows",
             fn -> Banking.upsert_transactions(account, transactions(extraction)) end,
             document_id: document.id,
             filename: document.filename
           ),
         {:ok, _document} <-
           timed(
             "bank_extract.document_update",
             fn ->
               Documents.update_document(document, %{
                 status: "needs_review",
                 extracted_at: DateTime.utc_now()
               })
             end,
             document_id: document.id,
             filename: document.filename
           ),
         :ok <-
           Banking.broadcast_progress(
             document.org_id,
             {:bank_done, document.id, account.id, count}
           ) do
      Logger.info(
        "bank_extract.complete document_id=#{document.id} filename=#{inspect(document.filename)} transactions=#{count} duration_ms=#{elapsed_ms(started_at)}"
      )

      :ok
    else
      {:error, reason} -> handle_failure(document, job, reason)
    end
  end

  defp upsert_account(document, extraction) do
    account_attrs = Map.get(extraction, "account", %{})

    Banking.upsert_account(%{
      org_id: document.org_id,
      account_number_masked: account_attrs["account_number_masked"],
      ifsc: account_attrs["ifsc"],
      bank_name: account_attrs["bank_name"],
      label: account_attrs["label"]
    })
  end

  defp transactions(extraction), do: Map.get(extraction, "transactions", [])

  defp handle_failure(document, job, reason) do
    Logger.error(
      "bank_extract.failed document_id=#{document.id} filename=#{inspect(document.filename)} attempt=#{attempt(job)} max_attempts=#{max_attempts(job)} reason=#{inspect(reason)}"
    )

    if last_attempt?(job) do
      {:ok, failed_document} = Documents.mark_failed(document)

      Banking.broadcast_progress(
        failed_document.org_id,
        {:bank_failed, failed_document.id, reason}
      )
    end

    {:error, reason}
  end

  defp last_attempt?(job), do: attempt(job) >= max_attempts(job)
  defp attempt(%{attempt: attempt}) when is_integer(attempt) and attempt > 0, do: attempt
  defp attempt(_job), do: 1

  defp max_attempts(%{max_attempts: max_attempts})
       when is_integer(max_attempts) and max_attempts > 0,
       do: max_attempts

  defp max_attempts(_job), do: 3

  defp extractor do
    Application.get_env(:nila, :bank_extractor, Nila.Banking.Extractor.Stub)
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
