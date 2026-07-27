defmodule Nila.Gst.Intake.DumpWorker do
  @moduledoc """
  Extracts one dump and re-derives the month from the union of all dumps.

  Intake is accretive (see `Nila.Gst.Intake.Dumps`): this worker only ever reads the
  files of the dump it was enqueued for — a two-bill straggler never re-reads
  the fifty-page main pile. Extraction output (normalized invoices, ids and
  image names namespaced by dump) persists on the dump row; the month is then
  rebuilt from the union across dumps and upserted back to `worked`, which
  demotes a reviewed month — the review no longer covers the changed month.

  A *signed* artifact is a wall here like everywhere else: when a live
  signature covers the side this dump feeds, the dump is extracted but marked
  `held` — stored, ready, not derived — until a senior reopens the signature
  and the dump is released. If that side is already filed, the dump is marked
  terminal `after_filing` instead: a filed return cannot be reworked.

  Extraction is minutes-long and fallible: progress narrates over PubSub
  (`PurchaseMonths.broadcast_progress/2`, message `{:gst_dump_progress, ...}`)
  and terminal failure marks the dump `failed` so intake surfaces can show
  which arrival broke. A windowed extractor reports each window as it lands, so
  the coarse `:extracting` stage is followed by `{:extracting, progress}` counts
  (`t:Nila.Gst.Extraction.Windowed.progress/0`) and the wait is narrated in
  pages read rather than a spinner.
  """
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias Nila.Clients

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Filing.{Gstr2b, Signoffs}
  alias Nila.Gst.Intake.{Dump, Dumps, ExtractionAttempts, Preconditions}
  alias Nila.Gst.Purchase.{Books, Flags, Reconciliation, Register, TaxpayerContext}
  alias Nila.Gst.Purchase.Month, as: PurchaseMonth
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Month, as: SalesMonth
  alias Nila.Gst.Sales.Months, as: SalesMonths

  alias Nila.Storage

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dump_id" => dump_id}} = job) do
    case Nila.Repo.fetch(Dump, dump_id) do
      {:ok, dump} ->
        try do
          do_perform(dump, job.attempt)
        rescue
          exception ->
            handle_failure(dump, job, Exception.format(:error, exception, __STACKTRACE__))
            reraise exception, __STACKTRACE__
        end

      {:error, :not_found} ->
        {:cancel, :dump_deleted}
    end
  end

  # Preconditions come between reading and deriving, on the same seam the wall
  # check sits on: a dump can be fully extracted and deliberately not derived.
  # A packet whose contents do not answer to the month it was filed under is a
  # question about whether this is the right work at all, and questions are
  # answered once — before they can turn into a pile of exceptions that are
  # each individually unanswerable.
  defp do_perform(dump, worker_attempt) do
    with {:ok, dump} <- extract(dump, worker_attempt) do
      case Preconditions.check(dump) do
        nil -> settle(dump)
        finding -> ask(dump, finding)
      end
    end
  end

  defp ask(dump, finding) do
    dump = Dumps.mark_needs_confirmation(dump, finding)
    progress(dump, :needs_confirmation)
    :ok
  end

  # Wall check + derivation run in one transaction holding FOR UPDATE on the
  # month row — the same lock `Signoffs.sign_off_gstr1` takes and the 3B
  # sign-off's state flip contends on — so a senior signing between our check
  # and our upsert is impossible: whoever gets the lock first wins, and the
  # loser sees the winner's work. A month that doesn't exist yet can't be
  # signed, so no lock is needed.
  #
  # Public because it is the whole of "derive from what this dump already holds":
  # a backfill that changes a dump's stored invoices without re-reading the file
  # (`Nila.Gst.Intake.EvidenceBackfill`) has to rebuild the month, and it must
  # pass the same signature wall a fresh arrival does rather than upserting past
  # it.
  @doc false
  def settle(dump) do
    {:ok, outcome} =
      Nila.Repo.transact(fn ->
        month = lock_month(dump)

        case wall_status(dump, month) do
          :after_filing ->
            Dumps.mark_after_filing(dump)
            {:ok, :after_filing}

          :held ->
            Dumps.mark_held(dump)
            {:ok, :held}

          :open ->
            derive(dump)
            {:ok, :done}
        end
      end)

    case outcome do
      :after_filing -> progress(dump, :after_filing)
      :held -> progress(dump, :held)
      :done -> progress(dump, {:done, dump.client_id, dump.period})
    end

    :ok
  end

  defp lock_month(%Dump{kind: "sales"} = dump) do
    Nila.Repo.one(
      from m in SalesMonth,
        where:
          m.org_id == ^dump.org_id and m.client_id == ^dump.client_id and
            m.period == ^dump.period,
        lock: "FOR UPDATE"
    )
  end

  defp lock_month(%Dump{} = dump) do
    Nila.Repo.one(
      from m in PurchaseMonth,
        where:
          m.org_id == ^dump.org_id and m.client_id == ^dump.client_id and
            m.period == ^dump.period,
        lock: "FOR UPDATE"
    )
  end

  # ---------------------------------------------------------------------------
  # Extraction — per dump, output persisted on the dump row. Already-extracted
  # dumps (a held dump being released) skip straight to derivation.
  # ---------------------------------------------------------------------------

  defp extract(%Dump{status: "held"} = dump, _worker_attempt), do: {:ok, dump}
  defp extract(%Dump{status: "extracted"} = dump, _worker_attempt), do: {:ok, dump}
  defp extract(%Dump{status: "needs_confirmation"} = dump, _worker_attempt), do: {:ok, dump}

  defp extract(%Dump{} = dump, worker_attempt) do
    dump = Dumps.mark_extracting(dump)
    progress(dump, :extracting)

    with {:ok, invoices, meta} <- extract_kind(dump, worker_attempt) do
      {:ok, Dumps.mark_extracted(dump, invoices, meta)}
    else
      {:error, reason} ->
        Dumps.mark_failed(dump, inspect(reason))
        progress(dump, {:failed, reason})
        {:error, reason}
    end
  end

  defp extract_kind(%Dump{kind: "gstr2b"} = dump, _worker_attempt) do
    with {:ok, key} <- one_source_key(dump),
         {:ok, bytes} <- Storage.get(key),
         {:ok, entries} <- Gstr2b.parse(bytes) do
      {:ok, entries, %{}}
    end
  end

  defp extract_kind(%Dump{kind: "purchase"} = dump, worker_attempt) do
    with {:ok, %{pages: pages, images: images} = result} <-
           extract_source(dump, purchase_extractor(), worker_attempt) do
      %{"invoices" => invoices, "skipped_pages" => skipped} = Books.normalize(pages)

      invoices =
        Enum.map(invoices, fn invoice ->
          invoice
          |> Map.update!("id", &namespace(dump, &1))
          |> Map.update("images", [], fn paths ->
            Enum.map(paths, &namespace(dump, Path.basename(&1)))
          end)
        end)

      store_evidence(dump, images, &PurchaseMonths.evidence_key/4)

      {:ok, invoices,
       %{
         "skipped_pages" => skipped,
         "unaccounted_pages" => unaccounted_pages(result),
         "evidence_unavailable" => evidence_unavailable?(result)
       }}
    end
  end

  defp extract_kind(%Dump{kind: "sales"} = dump, worker_attempt) do
    with {:ok, %{pages: pages, images: images} = result} <-
           extract_source(dump, sales_extractor(), worker_attempt) do
      invoices =
        Enum.map(pages, fn page ->
          image = page["image"] && namespace(dump, Path.basename(page["image"]))

          page
          |> Gstr1.normalize_invoice()
          |> Map.put("image", image)
        end)

      store_evidence(dump, images, &SalesMonths.evidence_key/4)

      {:ok, invoices,
       %{
         "unaccounted_pages" => unaccounted_pages(result),
         "evidence_unavailable" => evidence_unavailable?(result)
       }}
    end
  end

  defp unaccounted_pages(result), do: Map.get(result, :unaccounted_pages) || []

  # Pages that could not be rendered are a hole in the evidence a reviewer
  # checks a line against, not a failed read — so the dump lands, and the hole
  # is recorded here for derivation to flag rather than left to look like a
  # packet that simply had nothing to show.
  defp evidence_unavailable?(result), do: not is_nil(Map.get(result, :evidence_error))

  # A windowed extractor makes one provider call per page window, so the audit
  # row is per call, not per dump: it takes the attempt-persisting wrapper and
  # applies it around each one, tagging the row with the window's page range.
  defp extract_source(dump, extractor, worker_attempt) do
    with {:ok, key} <- one_source_key(dump),
         {:ok, bytes} <- Storage.get(key) do
      opts = [
        filename: Path.basename(key),
        on_progress: fn _stage -> :ok end,
        on_window: fn
          {:progress, window} -> progress(dump, {:extracting, window})
          {:retrying, pages} -> progress(dump, {:extracting_retry, pages})
        end
      ]

      cond do
        not audited?(extractor) ->
          extractor.extract(bytes, opts)

        per_call?(extractor) ->
          wrapper = fn metadata, call ->
            with_attempt(dump, key, bytes, extractor, worker_attempt, metadata, call)
          end

          extractor.extract(bytes, Keyword.put(opts, :per_call, wrapper))

        true ->
          with_attempt(dump, key, bytes, extractor, worker_attempt, %{}, fn ->
            extractor.extract(bytes, opts)
          end)
      end
    end
  end

  defp audited?(extractor) do
    exports?(extractor, :provider, 0) and exports?(extractor, :model, 0)
  end

  defp per_call?(extractor), do: exports?(extractor, :per_call?, 0) and extractor.per_call?()

  defp exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp with_attempt(dump, key, bytes, extractor, worker_attempt, metadata, call) do
    started_at = DateTime.utc_now()
    started_native = System.monotonic_time()

    with {:ok, attempt} <-
           ExtractionAttempts.start(dump, %{
             source_storage_key: key,
             provider: extractor.provider(),
             model: extractor.model(),
             worker_attempt: worker_attempt,
             source_byte_size: byte_size(bytes),
             started_at: started_at,
             request_metadata: metadata
           }) do
      try do
        case call.() do
          {:ok, result} ->
            finish_attempt(attempt, :succeeded, result, started_native)

          {:error, reason, audit} ->
            finish_attempt(attempt, {:failed, reason}, %{audit: audit}, started_native)

          {:error, reason} ->
            finish_attempt(attempt, {:failed, reason}, %{}, started_native)
        end
      rescue
        exception ->
          _ =
            ExtractionAttempts.fail(attempt, %{
              completed_at: DateTime.utc_now(),
              duration_ms: elapsed_ms(started_native),
              error: Exception.message(exception)
            })

          reraise exception, __STACKTRACE__
      end
    end
  end

  defp finish_attempt(attempt, :succeeded, result, started_native) do
    audit = Map.get(result, :audit, %{})

    attrs =
      audit
      |> audit_attrs()
      |> Map.put(:completed_at, DateTime.utc_now())
      |> Map.put(:duration_ms, elapsed_ms(started_native))

    case ExtractionAttempts.succeed(attempt, attrs) do
      {:ok, _attempt} -> {:ok, drop_raw_response(result)}
      {:error, reason} -> {:error, {:extraction_attempt_persistence_failed, reason}}
    end
  end

  defp finish_attempt(attempt, {:failed, reason}, result, started_native) do
    attrs =
      result
      |> Map.get(:audit, %{})
      |> audit_attrs()
      |> Map.put(:completed_at, DateTime.utc_now())
      |> Map.put(:duration_ms, elapsed_ms(started_native))
      |> Map.put(:error, inspect(reason, limit: 20, printable_limit: 2_000))

    case ExtractionAttempts.fail(attempt, attrs) do
      {:ok, _attempt} ->
        {:error, reason}

      {:error, persistence_reason} ->
        {:error, {:extraction_attempt_persistence_failed, persistence_reason, reason}}
    end
  end

  # The raw response lives on the attempt row now; carrying a copy of every
  # window's JSON back up the call stack is pure memory.
  defp drop_raw_response(%{audit: audit} = result) when is_map(audit),
    do: %{result | audit: Map.drop(audit, [:raw_response])}

  defp drop_raw_response(result), do: result

  defp audit_attrs(audit) do
    Map.take(audit, [
      :provider_request_id,
      :http_status,
      :source_page_count,
      :usage,
      :raw_response
    ])
  end

  defp elapsed_ms(started_native) do
    System.monotonic_time()
    |> Kernel.-(started_native)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp one_source_key(%Dump{file_keys: [key]}) when is_binary(key), do: {:ok, key}
  defp one_source_key(%Dump{}), do: {:error, :dump_must_have_exactly_one_source_file}

  # Basenames namespaced per dump so two dumps' page_01.png never collide in
  # tenant storage — and ids likewise, so unions concatenate without renumbering.
  defp namespace(%Dump{id: id}, basename), do: "d#{id}_#{basename}"

  defp store_evidence(dump, images, key_fun) do
    Enum.each(images, fn {basename, bytes} ->
      basename = namespace(dump, basename)
      key = key_fun.(dump.org_id, dump.client_id, dump.period, basename)
      {:ok, _} = Storage.put(key, bytes, content_type: evidence_content_type(basename))
    end)
  end

  defp evidence_content_type(basename) do
    case Path.extname(basename) do
      ".png" -> "image/png"
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end

  # ---------------------------------------------------------------------------
  # The wall — a filed side is terminal; a live unfiled signature holds.
  # ---------------------------------------------------------------------------

  defp wall_status(_dump, nil), do: :open

  defp wall_status(%Dump{kind: "sales"}, %SalesMonth{filed_at: filed_at})
       when not is_nil(filed_at),
       do: :after_filing

  defp wall_status(%Dump{kind: "sales"}, %SalesMonth{} = month) do
    if match?({:ok, _}, Signoffs.latest_gstr1_signoff(month.id)), do: :held, else: :open
  end

  defp wall_status(%Dump{}, %PurchaseMonth{filed_at: filed_at}) when not is_nil(filed_at),
    do: :after_filing

  defp wall_status(%Dump{}, %PurchaseMonth{} = month) do
    if match?({:ok, _}, Signoffs.latest_signoff(month.id)), do: :held, else: :open
  end

  # ---------------------------------------------------------------------------
  # Derivation — the month rebuilt from the union across dumps. Upserting back
  # to "worked" demotes a reviewed month; resolutions replay at read time over
  # the new pristine base, and survive because prior dumps' ids never moved.
  # ---------------------------------------------------------------------------

  defp derive(%Dump{kind: "sales"} = dump) do
    progress(dump, :deriving)
    invoices = Dumps.union_invoices(dump.org_id, dump.client_id, dump.period, "sales")

    {:ok, client} = Clients.get_client(dump.org_id, dump.client_id)

    issues =
      ledger_issues(dump, "sales") ++ Gstr1.validation_issues(invoices)

    derived = Gstr1.derive(invoices, Gstr1.production_header(client.gstin, dump.period))

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: dump.org_id,
        client_id: dump.client_id,
        period: dump.period,
        state: "worked",
        invoices: invoices,
        derived_gstr1: derived,
        issues: issues,
        summary: %{"invoice_count" => length(invoices), "issue_count" => length(issues)}
      })

    :ok
  end

  defp derive(%Dump{} = dump) do
    progress(dump, :reconciling)
    invoices = Dumps.union_invoices(dump.org_id, dump.client_id, dump.period, "purchase")

    gstr2b =
      dump.org_id
      |> Dumps.effective(dump.client_id, dump.period, "gstr2b")
      |> Enum.flat_map(& &1.invoices)
      |> Enum.map(&Dumps.rehydrate/1)

    {:ok, client} = Clients.get_client(dump.org_id, dump.client_id)
    entity_ctx = TaxpayerContext.for_client(client)
    vendor_dir = Map.new(gstr2b, fn g -> {g["vendor_gstin"], g["vendor_name"]} end)

    recon = Reconciliation.reconcile(invoices, gstr2b)
    flags = Flags.evaluate_all(invoices, entity_ctx, vendor_dir)
    rows = Register.rows(invoices, recon, flags)

    unaccounted = Dumps.unaccounted_pages(dump.org_id, dump.client_id, dump.period, "purchase")
    evidence_gaps = Dumps.evidence_gaps(dump.org_id, dump.client_id, dump.period, "purchase")
    document_flags = Flags.document_flags(unaccounted) ++ Flags.evidence_flags(evidence_gaps)

    {:ok, _} =
      PurchaseMonths.upsert(%{
        org_id: dump.org_id,
        client_id: dump.client_id,
        period: dump.period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Map.put(Register.summary(rows), "document_flags", document_flags)
      })

    :ok
  end

  # The sales side already renders month-level issues (`"invoice" => nil`), so
  # the ledger lands there rather than in a second surface.
  defp ledger_issues(dump, kind) do
    unaccounted =
      dump.org_id
      |> Dumps.unaccounted_pages(dump.client_id, dump.period, kind)
      |> Enum.map(fn %{"source" => source, "pages" => pages} ->
        %{
          "invoice" => nil,
          "code" => "pages_unaccounted",
          "level" => "warning",
          "message" =>
            "pages #{Enum.join(pages, ", ")} of #{source} produced no invoice. Open the " <>
              "original and confirm no bill was missed.",
          "fields" => ["doc_issue"]
        }
      end)

    evidence =
      dump.org_id
      |> Dumps.evidence_gaps(dump.client_id, dump.period, kind)
      |> Enum.map(fn %{"source" => source} ->
        %{
          "invoice" => nil,
          "code" => "evidence_unavailable",
          "level" => "warning",
          "message" =>
            "#{source} was read, but its pages could not be rendered, so no scanned bill " <>
              "shows beside these invoices. Check them against the original before signing.",
          "fields" => ["doc_issue"]
        }
      end)

    unaccounted ++ evidence
  end

  defp handle_failure(dump, job, reason) do
    Logger.error(
      "gst_dump.failed dump_id=#{dump.id} org_id=#{dump.org_id} client_id=#{dump.client_id} period=#{dump.period} kind=#{dump.kind} attempt=#{job.attempt} reason=#{inspect(reason)}"
    )

    if job.attempt >= job.max_attempts do
      Dumps.mark_failed(dump, reason)
      progress(dump, {:failed, reason})
    end

    :ok
  end

  defp progress(dump, message) do
    PurchaseMonths.broadcast_progress(
      dump.org_id,
      {:gst_dump_progress, dump.id, dump.client_id, dump.period, dump.kind, message}
    )
  end

  defp purchase_extractor do
    Application.get_env(:nila, :purchase_extractor, Nila.Gst.Extraction.Purchase.MistralOCR)
  end

  defp sales_extractor do
    Application.get_env(:nila, :sales_extractor, Nila.Gst.Extraction.Sales.MistralOCR)
  end
end
