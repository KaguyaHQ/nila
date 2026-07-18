defmodule Nila.Gst.DumpWorker do
  @moduledoc """
  Extracts one dump and re-derives the month from the union of all dumps.

  Intake is accretive (see `Nila.Gst.Dumps`): this worker only ever reads the
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
  (`ClientMonths.broadcast_progress/2`, message `{:gst_dump_progress, ...}`)
  and terminal failure marks the dump `failed` so intake surfaces can show
  which arrival broke.
  """
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias Nila.Clients

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.{
    ClientMonth,
    ClientMonths,
    Dump,
    Dumps,
    SalesMonth,
    EntityContext,
    Flags,
    Gstr1,
    Gstr2b,
    PurchaseBooks,
    Recon,
    Register,
    SalesMonths,
    Signoffs
  }

  alias Nila.Storage

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dump_id" => dump_id}} = job) do
    case Nila.Repo.fetch(Dump, dump_id) do
      {:ok, dump} ->
        try do
          do_perform(dump)
        rescue
          exception ->
            handle_failure(dump, job, Exception.format(:error, exception, __STACKTRACE__))
            reraise exception, __STACKTRACE__
        end

      {:error, :not_found} ->
        {:cancel, :dump_deleted}
    end
  end

  # Wall check + derivation run in one transaction holding FOR UPDATE on the
  # month row — the same lock `Signoffs.sign_off_gstr1` takes and the 3B
  # sign-off's state flip contends on — so a senior signing between our check
  # and our upsert is impossible: whoever gets the lock first wins, and the
  # loser sees the winner's work. A month that doesn't exist yet can't be
  # signed, so no lock is needed.
  defp do_perform(dump) do
    with {:ok, dump} <- extract(dump) do
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
      from m in ClientMonth,
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

  defp extract(%Dump{status: "held"} = dump), do: {:ok, dump}
  defp extract(%Dump{status: "extracted"} = dump), do: {:ok, dump}

  defp extract(%Dump{} = dump) do
    dump = Dumps.mark_extracting(dump)
    progress(dump, :extracting)

    with {:ok, invoices, meta} <- extract_kind(dump) do
      {:ok, Dumps.mark_extracted(dump, invoices, meta)}
    else
      {:error, reason} ->
        Dumps.mark_failed(dump, inspect(reason))
        progress(dump, {:failed, reason})
        {:error, reason}
    end
  end

  defp extract_kind(%Dump{kind: "gstr2b"} = dump) do
    with {:ok, bytes} <- Storage.get(hd(dump.file_keys)),
         {:ok, entries} <- Gstr2b.parse(bytes) do
      {:ok, entries, %{}}
    end
  end

  defp extract_kind(%Dump{kind: "purchase"} = dump) do
    with {:ok, %{pages: pages, images: images}} <- extract_pdf(dump, purchase_extractor()) do
      %{"invoices" => invoices, "skipped_pages" => skipped} = PurchaseBooks.normalize(pages)

      invoices =
        Enum.map(invoices, fn invoice ->
          invoice
          |> Map.update!("id", &namespace(dump, &1))
          |> Map.update("images", [], fn paths ->
            Enum.map(paths, &namespace(dump, Path.basename(&1)))
          end)
        end)

      store_evidence(dump, images, &ClientMonths.evidence_key/4)
      {:ok, invoices, %{"skipped_pages" => skipped}}
    end
  end

  defp extract_kind(%Dump{kind: "sales"} = dump) do
    with {:ok, %{pages: pages, images: images}} <- extract_pdf(dump, sales_extractor()) do
      invoices =
        Enum.map(pages, fn page ->
          image = page["image"] && namespace(dump, Path.basename(page["image"]))

          page
          |> Gstr1.normalize_invoice()
          |> Map.put("image", image)
        end)

      store_evidence(dump, images, &SalesMonths.evidence_key/4)
      {:ok, invoices, %{}}
    end
  end

  defp extract_pdf(dump, extractor) do
    with {:ok, bytes} <- Storage.get(hd(dump.file_keys)) do
      extractor.extract(bytes, filename: "bills.pdf", on_progress: fn _stage -> :ok end)
    end
  end

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

  defp wall_status(%Dump{}, %ClientMonth{filed_at: filed_at}) when not is_nil(filed_at),
    do: :after_filing

  defp wall_status(%Dump{}, %ClientMonth{} = month) do
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
    issues = Gstr1.validation_issues(invoices)
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
    entity_ctx = EntityContext.for_client(client)
    vendor_dir = Map.new(gstr2b, fn g -> {g["vendor_gstin"], g["vendor_name"]} end)

    recon = Recon.reconcile(invoices, gstr2b)
    flags = Flags.evaluate_all(invoices, entity_ctx, vendor_dir)
    rows = Register.rows(invoices, recon, flags)

    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: dump.org_id,
        client_id: dump.client_id,
        period: dump.period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    :ok
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
    ClientMonths.broadcast_progress(
      dump.org_id,
      {:gst_dump_progress, dump.id, dump.client_id, dump.period, dump.kind, message}
    )
  end

  defp purchase_extractor do
    Application.get_env(:nila, :purchase_extractor, Nila.Gst.PurchaseExtractor.Stub)
  end

  defp sales_extractor do
    Application.get_env(:nila, :sales_extractor, Nila.Gst.SalesExtractor.Stub)
  end
end
