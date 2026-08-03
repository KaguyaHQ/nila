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
  which arrival broke. The extractor reports each unit as it lands, so the
  coarse `:extracting` stage is followed by `{:extracting, progress}` counts
  (`t:Nila.Gst.Extraction.Pipeline.progress/0`) and the wait is narrated in
  pages labelled and bills read rather than a spinner.
  """
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias Nila.Clients

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Chase.CompletenessSender
  alias Nila.Gst.Filing.{Gstr2b, PortalDocument, Signoffs}
  alias Nila.Gst.Hsn.{Directory, Validation}
  alias Nila.Gst.Intake.{Dump, Dumps, ExtractionAttempts, Preconditions}
  alias Nila.Gst.Issues
  alias Nila.Gst.Purchase.{Books, Flags, Reconciliation, Register, TaxpayerContext}
  alias Nila.Gst.Purchase.Month, as: PurchaseMonth
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.Gst.RateHistory
  alias Nila.Gst.Rates.Directory, as: RateDirectory
  alias Nila.Gst.Rates.Validation, as: RateValidation
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Month, as: SalesMonth
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Workings, as: SalesWorkings

  alias Nila.Storage

  require Logger

  # Oban's default is `:infinity`. A packet reads as one OCR call plus one small
  # call per page and per bill, each of which may retry with backoff, so a
  # rate-limited month could otherwise hold one of five queue slots for hours
  # with nothing able to cancel it. Thirty minutes is far above any measured
  # read (a 57-page packet is ~2 minutes) and far below "forever".
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

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
  #
  # `clear_precondition/1` is a no-op on the arrival path and load-bearing on
  # the re-check path: a questioned dump re-enqueued after its sibling moved
  # has to *leave* `needs_confirmation` before `settle/1` runs, or derivation
  # rebuilds the month from every effective dump except the one whose question
  # just stopped standing — a silently emptied month, from a re-check that
  # reported success.
  defp do_perform(dump, worker_attempt) do
    with {:ok, dump} <- extract(dump, worker_attempt) do
      case Preconditions.check(dump) do
        nil -> dump |> Dumps.clear_precondition() |> settle()
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
      :after_filing ->
        progress(dump, :after_filing)

      :held ->
        progress(dump, :held)

      :done ->
        progress(dump, {:done, dump.client_id, dump.period})
        if dump.kind == "sales", do: CompletenessSender.enqueue(dump)
    end

    :ok
  end

  # Re-derives this dump's month from whatever is *currently* effective, without
  # touching the dump's own status.
  #
  # `settle/1` is the arrival path: it decides what the dump becomes. This is the
  # departure path — a dump that just left the effective set (questioned by
  # `Nila.Gst.Intake.PreconditionSweep`) leaves a month still holding its
  # invoices, and that month has to be rebuilt from the remainder. The dump is
  # passed only for the `(org, client, period, kind)` it names; its own invoices
  # are excluded by `Dumps.effective/4` the moment its status leaves `extracted`.
  #
  # Same lock and same wall as `settle/1`: a month whose side is signed or filed
  # is reported, never rebuilt behind the signature.
  @doc false
  def rederive(%Dump{} = dump) do
    Nila.Repo.transact(fn ->
      case wall_status(dump, lock_month(dump)) do
        :open ->
          derive(dump)
          {:ok, :derived}

        walled ->
          {:ok, walled}
      end
    end)
  end

  # Whether this dump's month is open, `:held` behind a live signature, or
  # `:after_filing`. Read without a lock — a caller deciding whether it is even
  # worth opening a transaction, not one about to write.
  @doc false
  def wall_state(%Dump{} = dump), do: wall_status(dump, Nila.Repo.one(month_query(dump)))

  defp lock_month(%Dump{} = dump),
    do: Nila.Repo.one(from m in month_query(dump), lock: "FOR UPDATE")

  defp month_query(%Dump{kind: kind} = dump) when kind in ~w(sales filed_gstr1) do
    from m in SalesMonth,
      where:
        m.org_id == ^dump.org_id and m.client_id == ^dump.client_id and
          m.period == ^dump.period
  end

  defp month_query(%Dump{} = dump) do
    from m in PurchaseMonth,
      where:
        m.org_id == ^dump.org_id and m.client_id == ^dump.client_id and
          m.period == ^dump.period
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

  # The portal's own GSTR-1 download — already structured, so "extraction" is a
  # decode plus a shape check that refuses a 2B (whose gstin sits nested under
  # "data") declared as the filed return.
  defp extract_kind(%Dump{kind: "filed_gstr1"} = dump, _worker_attempt) do
    with {:ok, key} <- one_source_key(dump),
         {:ok, bytes} <- Storage.get(key),
         {:ok, filed} <- PortalDocument.parse_filed_gstr1(bytes) do
      {:ok, [filed], %{}}
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
        pages
        |> Enum.with_index(1)
        |> Enum.map(fn {artifact, ordinal} ->
          image = artifact["image"] && namespace(dump, Path.basename(artifact["image"]))
          source_id = "inv_" <> String.pad_leading(to_string(ordinal), 2, "0")

          artifact
          |> Gstr1.normalize_invoice()
          |> Map.put("id", namespace(dump, source_id))
          |> Map.put("image", image)
        end)

      store_evidence(dump, images, &SalesMonths.evidence_key/4)

      {:ok, invoices,
       %{
         "unaccounted_pages" => unaccounted_pages(result),
         "evidence_unavailable" => evidence_unavailable?(result)
       }
       |> put_source_page_count(result)
       |> put_cess_evaluation(result)}
    end
  end

  # The page count lives on the extraction attempt's audit, but the account a
  # reviewer reads ("15 pages read → 15 invoices") sums per month, so it is
  # copied onto the dump the month is derived from
  # (`Nila.Gst.Intake.Dumps.source_page_count/4`). A dump that predates this
  # leaves the key absent and the pages clause unsaid rather than guessed.
  defp put_source_page_count(meta, result) do
    case get_in(result, [:audit, :source_page_count]) do
      count when is_integer(count) and count > 0 -> Map.put(meta, "source_page_count", count)
      _unknown -> meta
    end
  end

  defp put_cess_evaluation(meta, result) do
    if get_in(result, [:audit, :cess_evaluated]) == true,
      do: Map.put(meta, "cess_evaluated", true),
      else: meta
  end

  defp unaccounted_pages(result), do: Map.get(result, :unaccounted_pages) || []

  # Pages that could not be rendered are a hole in the evidence a reviewer
  # checks a line against, not a failed read — so the dump lands, and the hole
  # is recorded here for derivation to flag rather than left to look like a
  # packet that simply had nothing to show.
  defp evidence_unavailable?(result), do: not is_nil(Map.get(result, :evidence_error))

  # The segmented extractor makes provider calls for three distinct stages, so
  # the audit row is per stage rather than per dump. The attempt-persisting
  # wrapper records each stage with its own metadata and result.
  defp extract_source(dump, extractor, worker_attempt) do
    with {:ok, key} <- one_source_key(dump),
         {:ok, bytes} <- Storage.get(key) do
      opts = [
        filename: Path.basename(key),
        # The client's own GSTIN is a fact we hold, so the read is told it
        # rather than left to infer it from the packet.
        client_gstin: client_gstin(dump),
        on_progress: fn
          {:progress, extraction} -> progress(dump, {:extracting, extraction})
          {:retrying, pages} -> progress(dump, {:extracting_retry, pages})
          _coarse_stage -> :ok
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

  defp client_gstin(%Dump{} = dump) do
    case Clients.get_client(dump.org_id, dump.client_id) do
      {:ok, client} -> client.gstin
      _not_found -> nil
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
      |> merge_metadata(attempt, audit)
      |> Map.put(:completed_at, DateTime.utc_now())
      |> Map.put(:duration_ms, elapsed_ms(started_native))

    case ExtractionAttempts.succeed(attempt, attrs) do
      {:ok, _attempt} -> {:ok, drop_raw_response(result)}
      {:error, reason} -> {:error, {:extraction_attempt_persistence_failed, reason}}
    end
  end

  defp finish_attempt(attempt, {:failed, reason}, result, started_native) do
    audit = Map.get(result, :audit, %{})

    attrs =
      audit
      |> audit_attrs()
      |> merge_metadata(attempt, audit)
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

  # What a call *learned* is only known when it finishes, and it belongs on the
  # same row as what it was asked to do: the extractor returns it as
  # `audit.metadata` and it is folded into the metadata the attempt opened with.
  defp merge_metadata(attrs, attempt, audit) do
    case Map.get(audit, :metadata) do
      metadata when is_map(metadata) and metadata != %{} ->
        Map.put(attrs, :request_metadata, Map.merge(attempt.request_metadata || %{}, metadata))

      _none ->
        attrs
    end
  end

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

  defp wall_status(%Dump{kind: kind}, %SalesMonth{filed_at: filed_at})
       when kind in ~w(sales filed_gstr1) and not is_nil(filed_at),
       do: :after_filing

  defp wall_status(%Dump{kind: kind}, %SalesMonth{} = month)
       when kind in ~w(sales filed_gstr1) do
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

  # A filed-return dump rebuilds the same sales month: the filed JSON is just
  # another projection of the dump pile, so re-deriving after any arrival
  # keeps `filed_gstr1` (latest filed dump wins) and the bills in step.
  defp derive(%Dump{kind: kind} = dump) when kind in ~w(sales filed_gstr1) do
    progress(dump, :deriving)
    invoices = Dumps.union_invoices(dump.org_id, dump.client_id, dump.period, "sales")

    {:ok, client} = Clients.get_client(dump.org_id, dump.client_id)
    directory = active_hsn_directory()
    rate_directory = active_rate_directory()

    compliance =
      %{
        rate_history: RateHistory.prior_observations(dump.org_id, dump.client_id, dump.period)
      }
      |> maybe_put_directory(directory)
      |> maybe_put_rate_directory(rate_directory)

    workings =
      SalesWorkings.materialize(
        invoices,
        [],
        Gstr1.production_header(client.gstin, dump.period),
        ledger_issues(dump, "sales"),
        compliance: compliance,
        cess_evaluated: sales_cess_evaluated?(dump)
      )

    issues = Enum.map(workings.issues, &Map.delete(&1, "status"))

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: dump.org_id,
        client_id: dump.client_id,
        period: dump.period,
        state: "worked",
        invoices: workings.invoices,
        derived_gstr1: workings.derived,
        issues: issues,
        cess_evaluated: sales_cess_evaluated?(dump),
        hsn_master_release_id: release_id(directory),
        gst_rate_release_id: release_id(rate_directory),
        filed_gstr1: Dumps.filed_gstr1(dump.org_id, dump.client_id, dump.period),
        summary: %{"invoice_count" => length(invoices), "issue_count" => length(issues)}
      })

    :ok
  end

  defp derive(%Dump{} = dump) do
    progress(dump, :reconciling)
    invoices = Dumps.union_invoices(dump.org_id, dump.client_id, dump.period, "purchase")
    directory = active_hsn_directory()
    rate_directory = active_rate_directory()

    invoices =
      invoices
      |> annotate_hsn(directory)
      |> annotate_rates(rate_directory)

    gstr2b =
      dump.org_id
      |> Dumps.effective(dump.client_id, dump.period, "gstr2b")
      |> Enum.flat_map(& &1.invoices)
      |> Enum.map(&Dumps.rehydrate/1)

    {:ok, client} = Clients.get_client(dump.org_id, dump.client_id)

    entity_ctx =
      client
      |> TaxpayerContext.for_client()
      |> maybe_put_purchase_directory(directory)
      |> maybe_put_purchase_rate_directory(rate_directory)

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
        hsn_master_release_id: release_id(directory),
        gst_rate_release_id: release_id(rate_directory),
        summary: Map.put(Register.summary(rows), "document_flags", document_flags)
      })

    :ok
  end

  defp active_hsn_directory do
    case Directory.active() do
      {:ok, directory} -> directory
      {:error, :not_found} -> nil
    end
  end

  defp active_rate_directory do
    case RateDirectory.active() do
      {:ok, directory} -> directory
      {:error, :not_found} -> nil
    end
  end

  defp annotate_hsn(invoices, nil), do: invoices
  defp annotate_hsn(invoices, directory), do: Validation.annotate_invoices(invoices, directory)

  defp annotate_rates(invoices, nil), do: invoices

  defp annotate_rates(invoices, directory),
    do: RateValidation.annotate_invoices(invoices, directory)

  defp maybe_put_directory(compliance, nil), do: compliance
  defp maybe_put_directory(compliance, directory), do: Map.put(compliance, :directory, directory)

  defp maybe_put_rate_directory(compliance, nil), do: compliance

  defp maybe_put_rate_directory(compliance, directory),
    do: Map.put(compliance, :rate_directory, directory)

  defp maybe_put_purchase_directory(entity_ctx, nil), do: entity_ctx

  defp maybe_put_purchase_directory(entity_ctx, directory),
    do: Map.put(entity_ctx, "hsn_directory", directory)

  defp maybe_put_purchase_rate_directory(entity_ctx, nil), do: entity_ctx

  defp maybe_put_purchase_rate_directory(entity_ctx, directory),
    do: Map.put(entity_ctx, "rate_directory", directory)

  defp release_id(nil), do: nil
  defp release_id(directory), do: directory.release.id

  defp sales_cess_evaluated?(dump) do
    dumps = Dumps.effective(dump.org_id, dump.client_id, dump.period, "sales")
    dumps != [] and Enum.all?(dumps, &(&1.meta["cess_evaluated"] == true))
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
          "level" => Issues.level_for("pages_unaccounted"),
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
          "level" => Issues.level_for("evidence_unavailable"),
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
