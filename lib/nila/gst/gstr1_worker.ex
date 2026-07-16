defmodule Nila.Gst.Gstr1Worker do
  @moduledoc """
  Turns an uploaded sales-bills PDF into a worked `sales_month`, async.

  The outward mirror of `Nila.Gst.MonthWorker`, productionized from
  `scripts/extract_sales.exs` + `scripts/eval_gstr1.exs`:

      PDF → per-page extraction (`SalesExtractor`)
          → `Gstr1.normalize_invoice` → sales invoices
          → `Gstr1.validation_issues` → issues
          → `Gstr1.derive` → portal-shaped GSTR-1
          → store page images under tenant-scoped evidence keys
          → `SalesMonths.upsert` (state "worked")

  Unlike the purchase worker there is no GSTR-2B and no reconciliation — outward
  filing has a single input (the sales PDF) and derives the return that will be
  filed. `Gstr1.derive/2` was written against real filed returns for the eval;
  in production there is no filed return yet, so the worker derives into
  `Gstr1.production_header/2` (the client's own GSTIN + the filing period).

  Extraction is minutes-long and fallible, so the worker narrates each stage over
  PubSub (`SalesMonths.broadcast_progress/2`) and marks a terminal failure on the
  last attempt.
  """
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias Nila.Clients
  alias Nila.Gst.{Gstr1, SalesMonths}
  alias Nila.Storage

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    %{
      "org_id" => org_id,
      "client_id" => client_id,
      "period" => period,
      "pdf_key" => pdf_key
    } = args

    ctx = %{org_id: org_id, client_id: client_id, period: period}
    started_at = System.monotonic_time()

    try do
      do_perform(ctx, pdf_key, started_at)
    rescue
      exception ->
        handle_failure(ctx, job, Exception.format(:error, exception, __STACKTRACE__))
        reraise exception, __STACKTRACE__
    end
  end

  defp do_perform(ctx, pdf_key, started_at) do
    with :ok <- progress(ctx, :reading),
         {:ok, pdf_bytes} <- Storage.get(pdf_key),
         :ok <- progress(ctx, :extracting),
         {:ok, %{pages: pages, images: images}} <-
           extractor().extract(pdf_bytes,
             filename: "sales_bills.pdf",
             on_progress: fn _stage -> :ok end
           ),
         :ok <- progress(ctx, :deriving),
         {:ok, sales_month} <- build_and_upsert(ctx, pages, images) do
      progress(ctx, {:done, sales_month.client_id, sales_month.period})

      Logger.info(
        "gstr1_month.complete org_id=#{ctx.org_id} client_id=#{ctx.client_id} period=#{ctx.period} invoices=#{length(sales_month.invoices)} duration_ms=#{elapsed_ms(started_at)}"
      )

      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_and_upsert(ctx, pages, images) do
    {:ok, client} = Clients.get_client(ctx.org_id, ctx.client_id)

    invoices = Enum.map(pages, &Gstr1.normalize_invoice/1)
    issues = Gstr1.validation_issues(invoices)
    derived = Gstr1.derive(invoices, Gstr1.production_header(client.gstin, ctx.period))

    :ok = progress(ctx, :storing)
    store_evidence(ctx, pages, images)

    SalesMonths.upsert(%{
      org_id: ctx.org_id,
      client_id: ctx.client_id,
      period: ctx.period,
      state: "worked",
      invoices: invoices,
      derived_gstr1: derived,
      issues: issues,
      summary: summary(invoices, issues)
    })
  end

  defp summary(invoices, issues) do
    %{
      "invoice_count" => length(invoices),
      "issue_count" => length(issues)
    }
  end

  # Persist every rendered page image the extractor produced, under the same
  # tenant-scoped keys the evidence route reads from.
  defp store_evidence(ctx, pages, images) do
    pages
    |> Enum.map(& &1["image"])
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.map(&Path.basename/1)
    |> Enum.uniq()
    |> Enum.each(fn basename ->
      case Map.fetch(images, basename) do
        {:ok, bytes} ->
          key = SalesMonths.evidence_key(ctx.org_id, ctx.client_id, ctx.period, basename)
          {:ok, _} = Storage.put(key, bytes)

        :error ->
          :ok
      end
    end)
  end

  defp handle_failure(ctx, job, reason) do
    Logger.error(
      "gstr1_month.failed org_id=#{ctx.org_id} client_id=#{ctx.client_id} period=#{ctx.period} attempt=#{attempt(job)} max_attempts=#{max_attempts(job)} reason=#{inspect(reason)}"
    )

    if last_attempt?(job) do
      progress(ctx, {:failed, reason})
    end

    :ok
  end

  defp progress(ctx, message) do
    SalesMonths.broadcast_progress(
      ctx.org_id,
      {:gstr1_month_progress, ctx.client_id, ctx.period, message}
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
    Application.get_env(:nila, :sales_extractor, Nila.Gst.SalesExtractor.Stub)
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end
end
