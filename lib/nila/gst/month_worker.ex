defmodule Nila.Gst.MonthWorker do
  @moduledoc """
  Turns an uploaded purchase-bills PDF + a GSTR-2B file into a worked
  `client_month`, async.

  The full chain, productionized from `scripts/extract_purchases.exs` +
  `scripts/build_register.exs`:

      PDF  → per-page extraction (`PurchaseExtractor`)
           → `PurchaseBooks.normalize` → books invoices
      2B   → `Gstr2b.parse`
      then → `Recon.reconcile` + `Flags.evaluate_all`
           → `Register.rows` + `Register.summary`
           → store page images under tenant-scoped evidence keys
           → `ClientMonths.upsert` (state "worked")

  Extraction is minutes-long and fallible, so the worker narrates each stage
  over PubSub (`ClientMonths.broadcast_progress/2`) and marks a terminal failure
  on the last attempt. Modeled on `Nila.Documents.BankStatementExtractionWorker`.
  """
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias Nila.Clients
  alias Nila.Gst.{ClientMonths, EntityContext, Flags, Gstr2b, PurchaseBooks, Recon, Register}
  alias Nila.Storage

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    %{
      "org_id" => org_id,
      "client_id" => client_id,
      "period" => period,
      "pdf_key" => pdf_key,
      "gstr2b_key" => gstr2b_key
    } = args

    ctx = %{org_id: org_id, client_id: client_id, period: period}
    started_at = System.monotonic_time()

    try do
      do_perform(ctx, pdf_key, gstr2b_key, started_at)
    rescue
      exception ->
        handle_failure(ctx, job, Exception.format(:error, exception, __STACKTRACE__))
        reraise exception, __STACKTRACE__
    end
  end

  defp do_perform(ctx, pdf_key, gstr2b_key, started_at) do
    with :ok <- progress(ctx, :reading),
         {:ok, pdf_bytes} <- Storage.get(pdf_key),
         {:ok, gstr2b_bytes} <- Storage.get(gstr2b_key),
         :ok <- progress(ctx, :extracting),
         {:ok, %{pages: pages, images: images}} <-
           extractor().extract(pdf_bytes,
             filename: "purchase_bills.pdf",
             on_progress: fn _stage -> :ok end
           ),
         :ok <- progress(ctx, :assembling),
         %{"invoices" => invoices} <- PurchaseBooks.normalize(pages),
         {:ok, gstr2b} <- Gstr2b.parse(gstr2b_bytes),
         :ok <- progress(ctx, :reconciling),
         {:ok, client_month} <-
           build_and_upsert(ctx, invoices, gstr2b, images) do
      progress(ctx, {:done, client_month.client_id, client_month.period})

      Logger.info(
        "gst_month.complete org_id=#{ctx.org_id} client_id=#{ctx.client_id} period=#{ctx.period} invoices=#{length(invoices)} duration_ms=#{elapsed_ms(started_at)}"
      )

      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_and_upsert(ctx, invoices, gstr2b, images) do
    entity_ctx = entity_ctx(ctx.org_id, ctx.client_id)
    vendor_dir = Map.new(gstr2b, fn g -> {g["vendor_gstin"], g["vendor_name"]} end)

    recon = Recon.reconcile(invoices, gstr2b)
    flags = Flags.evaluate_all(invoices, entity_ctx, vendor_dir)
    rows = Register.rows(invoices, recon, flags)
    summary = Register.summary(rows)

    :ok = progress(ctx, :storing)
    store_evidence(ctx, rows, images)

    ClientMonths.upsert(%{
      org_id: ctx.org_id,
      client_id: ctx.client_id,
      period: ctx.period,
      state: "worked",
      register_rows: rows,
      recon: recon,
      summary: summary
    })
  end

  # Only persist the images the register actually references, under the same
  # tenant-scoped keys the workspace/evidence controller reads from.
  defp store_evidence(ctx, rows, images) do
    rows
    |> Enum.flat_map(&(&1["images"] || []))
    |> Enum.uniq()
    |> Enum.each(fn path ->
      basename = Path.basename(path)

      case Map.fetch(images, basename) do
        {:ok, bytes} ->
          key = ClientMonths.evidence_key(ctx.org_id, ctx.client_id, ctx.period, basename)
          {:ok, _} = Storage.put(key, bytes)

        :error ->
          :ok
      end
    end)
  end

  defp entity_ctx(org_id, client_id) do
    {:ok, client} = Clients.get_client(org_id, client_id)
    EntityContext.for_client(client)
  end

  defp handle_failure(ctx, job, reason) do
    Logger.error(
      "gst_month.failed org_id=#{ctx.org_id} client_id=#{ctx.client_id} period=#{ctx.period} attempt=#{attempt(job)} max_attempts=#{max_attempts(job)} reason=#{inspect(reason)}"
    )

    if last_attempt?(job) do
      progress(ctx, {:failed, reason})
    end

    :ok
  end

  defp progress(ctx, message) do
    ClientMonths.broadcast_progress(
      ctx.org_id,
      {:gst_month_progress, ctx.client_id, ctx.period, message}
    )
  end

  defp last_attempt?(job), do: attempt(job) >= max_attempts(job)
  defp attempt(%{attempt: attempt}) when is_integer(attempt) and attempt > 0, do: attempt
  defp attempt(_job), do: 1

  defp max_attempts(%{max_attempts: max_attempts})
       when is_integer(max_attempts) and max_attempts > 0,
       do: max_attempts

  defp max_attempts(_job), do: 3

  defp extractor do
    Application.get_env(:nila, :purchase_extractor, Nila.Gst.PurchaseExtractor.Stub)
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end
end
