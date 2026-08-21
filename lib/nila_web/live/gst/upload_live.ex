defmodule NilaWeb.Gst.UploadLive do
  use NilaWeb, :live_view

  @moduledoc """
  Bring in documents — the intake action. Documents arrive as sales bills, a
  shoebox of purchases, portal downloads, and stragglers after the chase. The
  operator drops the files first: bill PDFs and images are then labelled Sales or Purchase,
  while portal JSON is identified from its structure. Each file becomes a
  `Nila.Gst.Intake.Dump` and a `DumpWorker` job, and the month re-derives from the
  union of everything that has arrived.

  Accepts `?client_id=&period=` so Today rows and the workbench can open it
  pre-scoped to the client-month the documents belong to.
  """

  alias Nila.Clients
  alias Nila.Gst.Filing.{Calendar, PortalDocument}
  alias Nila.Gst.Intake.{Dumps, DumpWorker}
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Storage
  alias Nila.TallyDevices
  alias NilaWeb.Gst.PeriodOptions
  alias NilaWeb.Presence

  # Refuse oversized source files at intake rather than after rendering and
  # base64 expansion inside extraction.
  @max_pdf_bytes 50_000_000
  @max_image_bytes 20_000_000
  @max_json_bytes 20_000_000
  @max_upload_entries 10
  @max_sales_upload_entries 50
  @bill_extensions ~w(.pdf .jpg .jpeg .png .webp)

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: subscribe(socket)

    prefilled = prefill(socket, params)
    sales_intake? = socket.assigns.live_action == :sales

    if connected?(socket) and sales_intake?, do: subscribe_tally(socket)

    socket =
      socket
      |> assign(:page_title, if(sales_intake?, do: "Sales bills", else: "Bring in documents"))
      |> assign(:sales_intake?, sales_intake?)
      |> assign(:tally_state, nil)
      |> assign(:internal_period, prefilled["period"])
      |> assign(:clients, list_clients(socket))
      |> assign(:form, to_form(prefilled, as: :intake))
      |> assign_period_options(prefilled["client_id"])
      |> assign(:entry_kinds, %{})
      |> assign(:entry_keys, %{})
      |> assign(:jobs, %{})
      |> assign(:pending, nil)
      |> allow_upload(:documents,
        accept: if(sales_intake?, do: @bill_extensions, else: @bill_extensions ++ [".json"]),
        max_entries: if(sales_intake?, do: @max_sales_upload_entries, else: @max_upload_entries),
        max_file_size: @max_pdf_bytes,
        auto_upload: true,
        progress: &handle_upload_progress/3,
        validator: &validate_document_entry/1,
        external: &presign_upload/2
      )
      |> load_sales_tally_context()

    {:ok, assign(socket, :error, nil)}
  end

  defp prefill(socket, params) do
    period =
      if params["period"] in period_values(),
        do: params["period"],
        else: Calendar.closeable_period(Date.utc_today())

    %{
      "client_id" => permitted_client(socket, params["client_id"]),
      "period" => period
    }
  end

  defp permitted_client(socket, client_id) do
    if Enum.any?(socket.assigns[:clients] || list_clients(socket), fn {_name, id} ->
         to_string(id) == to_string(client_id)
       end),
       do: client_id,
       else: nil
  end

  @impl true
  def handle_event("validate", %{"intake" => params}, socket) do
    params = with_internal_period(socket, params)

    {:noreply,
     socket
     |> assign(:form, to_form(params, as: :intake))
     |> assign_period_options(params["client_id"])}
  end

  # Removing a row now has to take the object with it. The file reached the
  # bucket the moment it was dropped, and the dump row that would have pointed
  # at it is never written — so nothing downstream would ever collect it.
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {key, entry_keys} = Map.pop(socket.assigns.entry_keys, ref)
    if key, do: Storage.delete(key)

    {:noreply,
     socket
     |> cancel_upload(:documents, ref)
     |> assign(:entry_kinds, Map.delete(socket.assigns.entry_kinds, ref))
     |> assign(:entry_keys, entry_keys)}
  end

  def handle_event("choose-kind", %{"ref" => ref, "kind" => kind}, socket)
      when kind in ~w(sales purchase) do
    entry = Enum.find(socket.assigns.uploads.documents.entries, &(&1.ref == ref))

    entry_kinds =
      if entry && bill_entry?(entry) do
        Map.put(socket.assigns.entry_kinds, ref, {:ok, kind})
      else
        socket.assigns.entry_kinds
      end

    {:noreply, assign(socket, :entry_kinds, entry_kinds)}
  end

  def handle_event("choose-kind", _params, socket), do: {:noreply, socket}

  def handle_event("submit", %{"intake" => params}, socket) do
    org = socket.assigns.current_scope.current_org
    params = with_internal_period(socket, params)

    with {:ok, client_id} <- fetch_client(org, params["client_id"]),
         {:ok, period} <- fetch_period(params["period"]),
         {:ok, entry_kinds} <- ready_entries(socket) do
      dumps = create_dumps(socket, org.id, client_id, period, entry_kinds)

      jobs =
        dumps
        |> Map.new(fn dump ->
          {dump.id,
           %{
             kind: dump.kind,
             status: :queued,
             progress: nil,
             bill_count: nil,
             retrying: nil,
             worker_retry: nil,
             unaccounted: [],
             client_id: client_id,
             period: period
           }}
        end)

      {:noreply,
       socket
       |> assign(:entry_kinds, %{})
       |> assign(:entry_keys, %{})
       |> assign(:jobs, jobs)
       |> assign(:error, nil)
       |> assign(:pending, %{
         client_id: client_id,
         period: period,
         batch_ref: Nila.Gst.Sales.TallyPacket.ref(dumps)
       })}
    else
      {:error, message} ->
        {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("open-month", _params, %{assigns: %{sales_intake?: true}} = socket) do
    %{client_id: client_id, batch_ref: batch_ref} = socket.assigns.pending
    {:noreply, push_navigate(socket, to: ~p"/sales-bills/#{client_id}/batch/#{batch_ref}")}
  end

  def handle_event("open-month", _params, socket) do
    %{client_id: client_id, period: period} = socket.assigns.pending
    {:noreply, push_navigate(socket, to: ~p"/gst/#{client_id}/#{period}")}
  end

  def handle_event("try-again", _params, socket) do
    %{client_id: client_id, period: period} = socket.assigns.pending

    {:noreply,
     socket
     |> assign(:entry_kinds, %{})
     |> assign(:entry_keys, %{})
     |> assign(:jobs, %{})
     |> assign(
       :form,
       to_form(%{"client_id" => to_string(client_id), "period" => period}, as: :intake)
     )
     |> assign_period_options(client_id)}
  end

  # The bill goes from the operator's machine to the bucket and never through
  # this server. Streaming it over the LiveView channel instead costs a
  # serialized round trip per 64 KB — on a connection whose latency is the
  # constraint, that is the whole of the wait on a pile of scans.
  #
  # The key omits client and period on purpose. Both are still form fields the
  # operator can change after the file has landed, and a path that says October
  # under a dump row that says November is a lie the bucket would keep. The dump
  # row is the index; the key only has to be unique and org-scoped.
  defp presign_upload(entry, socket) do
    case socket.assigns.current_scope.current_org do
      %{id: org_id} ->
        key = "orgs/#{org_id}/dumps/#{Ecto.UUID.generate()}/original#{entry_extension(entry)}"

        case Storage.presign_put(key) do
          {:ok, url} ->
            meta = %{uploader: "Put", key: key, url: url}

            {:ok, meta,
             assign(socket, :entry_keys, Map.put(socket.assigns.entry_keys, entry.ref, key))}

          {:error, _reason} ->
            {:error, %{reason: :storage_unavailable}, storage_unavailable(socket)}
        end

      _no_org ->
        {:error, %{reason: :storage_unavailable}, storage_unavailable(socket)}
    end
  end

  # An entry refused here comes back to the client as LiveView's own "failed
  # preflight" and renders as a generic per-file error, which tells the operator
  # nothing they can act on. The page-level line is the only place that can say
  # the storage was unreachable and the drop is worth repeating.
  defp storage_unavailable(socket),
    do: assign(socket, :error, "Nila could not reach storage. Drop that file again.")

  defp handle_upload_progress(:documents, %{done?: true} = entry, socket) do
    entry_kinds =
      cond do
        socket.assigns.sales_intake? and bill_entry?(entry) ->
          Map.put(socket.assigns.entry_kinds, entry.ref, {:ok, "sales"})

        entry_extension(entry) == ".json" ->
          classification =
            consume_uploaded_entry(socket, entry, fn %{key: key} ->
              {:postpone, classify_portal_file(key)}
            end)

          Map.put(socket.assigns.entry_kinds, entry.ref, classification)

        true ->
          socket.assigns.entry_kinds
      end

    {:noreply, assign(socket, :entry_kinds, entry_kinds)}
  end

  defp handle_upload_progress(:documents, _entry, socket), do: {:noreply, socket}

  # The file is in the bucket rather than on a temp path, so identifying it
  # costs a read back. A fetch that fails is not an unrecognized portal file and
  # must not be reported as one.
  defp classify_portal_file(key) do
    case Storage.get(key) do
      {:ok, bytes} -> PortalDocument.classify(bytes)
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp validate_document_entry(entry) do
    extension = entry_extension(entry)

    cond do
      extension == ".json" and entry.client_size > @max_json_bytes ->
        {:error, :json_too_large}

      extension in (@bill_extensions -- [".pdf"]) and entry.client_size > @max_image_bytes ->
        {:error, :image_too_large}

      true ->
        :ok
    end
  end

  defp ready_entries(socket) do
    upload = socket.assigns.uploads.documents

    cond do
      upload.entries == [] ->
        {:error, "Drop at least one file."}

      upload_errors(upload) != [] or
          Enum.any?(upload.entries, &(upload_errors(upload, &1) != [])) ->
        {:error, "Remove the files with errors before bringing them in."}

      Enum.any?(upload.entries, &(not &1.done?)) ->
        {:error, "Wait for every file to finish uploading."}

      entry = Enum.find(upload.entries, &(not ready_entry?(&1, socket.assigns.entry_kinds))) ->
        {:error, entry_readiness_error(entry, socket.assigns.entry_kinds)}

      true ->
        {:ok, socket.assigns.entry_kinds}
    end
  end

  defp ready_entry?(entry, entry_kinds) do
    case {bill_entry?(entry), entry_extension(entry), Map.get(entry_kinds, entry.ref)} do
      {true, _extension, {:ok, kind}} when kind in ~w(sales purchase) -> true
      {false, ".json", {:ok, kind}} when kind in ~w(gstr2b filed_gstr1) -> true
      _ -> false
    end
  end

  defp entry_readiness_error(entry, entry_kinds) do
    case {bill_entry?(entry), entry_extension(entry), Map.get(entry_kinds, entry.ref)} do
      {true, _extension, _state} ->
        "Choose Sales or Purchase for #{entry.client_name}."

      {false, ".json", {:error, :invalid_json}} ->
        "#{entry.client_name} is not valid JSON."

      {false, ".json", {:error, :ambiguous_structure}} ->
        "#{entry.client_name} matches more than one portal format. Remove it and check the download."

      {false, ".json", {:error, :unreadable}} ->
        "Nila could not read #{entry.client_name} back after it uploaded. Remove it and try again."

      {false, ".json", nil} ->
        "Nila could not finish identifying #{entry.client_name}. Remove it and try again."

      {false, ".json", _state} ->
        "#{entry.client_name} is not a GSTR-2B or filed GSTR-1 portal file."
    end
  end

  defp create_dumps(socket, org_id, client_id, period, entry_kinds) do
    scope = socket.assigns.current_scope

    socket
    |> consume_uploaded_entries(:documents, fn %{key: key}, entry ->
      {:ok, kind} = Map.fetch!(entry_kinds, entry.ref)
      {:ok, {kind, key, entry.client_name}}
    end)
    |> Enum.map(fn {kind, key, original_name} ->
      meta =
        if socket.assigns.sales_intake?,
          do: %{"sales_batch" => true, "original_name" => original_name},
          else: %{}

      {:ok, dump} =
        Dumps.record(
          %{org_id: org_id, client_id: client_id, brought_in_by_id: scope.user.id},
          %{period: period, kind: kind, file_keys: [key], meta: meta}
        )

      {:ok, _job} = Oban.insert(DumpWorker.new(%{dump_id: dump.id}))
      dump
    end)
  end

  defp entry_extension(entry),
    do: entry.client_name |> Path.extname() |> String.downcase()

  defp bill_entry?(entry), do: entry_extension(entry) in @bill_extensions

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff"},
        %{assigns: %{sales_intake?: true, jobs: jobs}} = socket
      )
      when jobs == %{} do
    {:noreply, load_sales_tally_context(socket)}
  end

  def handle_info({:gst_dump_progress, dump_id, _client_id, _period, _kind, message}, socket) do
    case socket.assigns.jobs do
      %{^dump_id => job} = jobs ->
        jobs = Map.put(jobs, dump_id, apply_progress(job, message))

        {:noreply,
         socket
         |> assign(:jobs, jobs)
         |> open_sales_result_when_finished(jobs)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp open_sales_result_when_finished(
         %{assigns: %{sales_intake?: true, pending: pending}} = socket,
         jobs
       )
       when not is_nil(pending) do
    if not working?(jobs) do
      push_navigate(socket,
        to: ~p"/sales-bills/#{pending.client_id}/batch/#{pending.batch_ref}"
      )
    else
      socket
    end
  end

  defp open_sales_result_when_finished(socket, _jobs), do: socket

  defp apply_progress(job, {:done, _client_id, _period, unaccounted}),
    do: %{
      job
      | status: :done,
        progress: nil,
        retrying: nil,
        worker_retry: nil,
        unaccounted: unaccounted
    }

  defp apply_progress(job, {:failed, _reason}),
    do: %{job | status: :failed, worker_retry: nil}

  defp apply_progress(job, :held), do: %{job | status: :held, worker_retry: nil}

  defp apply_progress(job, {:worker_retrying, attempt, max_attempts}),
    do: %{
      job
      | retrying: nil,
        worker_retry: %{attempt: attempt, max_attempts: max_attempts, state: :waiting}
    }

  defp apply_progress(job, :extracting),
    do: %{
      job
      | status: :extracting,
        retrying: nil,
        worker_retry: start_worker_retry(job.worker_retry)
    }

  defp apply_progress(job, {:extracting, window}) when is_map(window),
    do: %{
      job
      | status: :extracting,
        progress: window,
        bill_count: bill_count(window, job.bill_count),
        retrying: nil
    }

  # A resent window costs another provider round-trip, so the bar sits still for
  # ~40s while it happens. Saying so is the difference between a slow read and a
  # screen that looks hung — the same reason the ledger refuses silence.
  defp apply_progress(job, {:extracting_retry, pages}),
    do: %{job | status: :extracting, retrying: pages}

  # Once every bill has landed, derivation and reconciliation are bookkeeping
  # over that completed read. Keep the full bar on screen while those short
  # checks run: replacing useful progress with another indeterminate animation
  # makes a normal phase transition look like the document restarted.
  defp apply_progress(job, stage) when stage in [:deriving, :reconciling],
    do: %{
      job
      | status: stage,
        progress: checking_progress(job.progress),
        retrying: nil,
        worker_retry: nil
    }

  defp apply_progress(job, stage) when is_atom(stage),
    do: %{job | status: stage, progress: nil, retrying: nil, worker_retry: nil}

  defp bill_count(%{stage: :reading, total: total}, _previous), do: total
  defp bill_count(_progress, previous), do: previous

  defp checking_progress(%{stage: :reading, total: total}),
    do: %{stage: :checking, done: total, total: total}

  defp checking_progress(_progress), do: nil

  defp start_worker_retry(nil), do: nil
  defp start_worker_retry(retry), do: %{retry | state: :running}

  defp fetch_client(org, client_id) do
    case org && client_id && client_id != "" && Clients.get_client(org.id, client_id) do
      {:ok, client} -> {:ok, client.id}
      _ -> {:error, "Pick a client."}
    end
  end

  defp fetch_period(period) when is_binary(period) do
    if period in period_values(),
      do: {:ok, period},
      else: {:error, "Pick a period."}
  end

  defp fetch_period(_period), do: {:error, "Pick a period."}

  defp with_internal_period(%{assigns: %{sales_intake?: true}} = socket, params),
    do: Map.put(params, "period", socket.assigns.internal_period)

  defp with_internal_period(_socket, params), do: params

  defp period_values, do: PeriodOptions.periods()

  # The period a pile lands in is the one field on this form the operator can
  # get wrong without noticing, so each option says what that month already
  # holds. Recomputed on every change because the client is itself a field.
  defp assign_period_options(socket, client_id) do
    org = socket.assigns.current_scope.current_org

    id =
      Enum.find_value(socket.assigns[:clients] || list_clients(socket), fn {_name, id} ->
        to_string(id) == to_string(client_id) && id
      end)

    assign(socket, :period_options, PeriodOptions.for_client(org && org.id, id))
  end

  defp subscribe(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}),
    do: ClientMonths.subscribe(org_id)

  defp subscribe(_socket), do: :ok

  defp list_clients(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    org_id
    |> Clients.list_clients()
    |> Enum.map(&{&1.name, &1.id})
  end

  defp list_clients(_socket), do: []

  defp load_sales_tally_context(%{assigns: %{sales_intake?: false}} = socket), do: socket

  defp load_sales_tally_context(
         %{assigns: %{current_scope: %{current_org: %{id: org_id}}}} = socket
       ) do
    devices = TallyDevices.list_active_devices(org_id)

    online_device_ids =
      "tally_devices:#{org_id}"
      |> Presence.list()
      |> Map.keys()
      |> MapSet.new()

    open_companies =
      org_id
      |> TallyDevices.list_open_companies()
      |> Enum.filter(&MapSet.member?(online_device_ids, Integer.to_string(&1.device_id)))

    cond do
      devices == [] ->
        assign_sales_tally_state(socket, :connect, [])

      MapSet.size(online_device_ids) == 0 ->
        assign_sales_tally_state(socket, :start_connector, [])

      open_companies == [] ->
        assign_sales_tally_state(socket, :open_company, [])

      true ->
        case ensure_company_clients(org_id, open_companies) do
          {:ok, company_clients} ->
            state =
              case company_clients do
                [{company, _client}] -> {:ready, company.name}
                _many -> :choose_company
              end

            assign_sales_tally_state(socket, state, company_clients)

          {:error, _reason} ->
            assign_sales_tally_state(socket, :unavailable, [])
        end
    end
  end

  defp load_sales_tally_context(socket), do: assign_sales_tally_state(socket, :connect, [])

  defp ensure_company_clients(org_id, companies) do
    Enum.reduce_while(companies, {:ok, []}, fn company, {:ok, company_clients} ->
      case TallyDevices.ensure_company_client(org_id, company.id) do
        {:ok, client} -> {:cont, {:ok, [{company, client} | company_clients]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, company_clients} -> {:ok, Enum.reverse(company_clients)}
      error -> error
    end
  end

  defp assign_sales_tally_state(socket, state, company_clients) do
    clients = Enum.map(company_clients, fn {company, client} -> {company.name, client.id} end)

    selected_client_id =
      case clients do
        [{_name, client_id}] -> Integer.to_string(client_id)
        _many -> permitted_client_id(socket.assigns.form[:client_id].value, clients)
      end

    form_values = %{
      "client_id" => selected_client_id,
      "period" => socket.assigns.internal_period
    }

    socket
    |> assign(:tally_state, state)
    |> assign(:clients, clients)
    |> assign(:form, to_form(form_values, as: :intake))
  end

  defp permitted_client_id(client_id, clients) do
    if Enum.any?(clients, fn {_name, id} -> to_string(id) == to_string(client_id) end),
      do: to_string(client_id),
      else: nil
  end

  defp subscribe_tally(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}),
    do: NilaWeb.Endpoint.subscribe("tally_devices:#{org_id}")

  defp subscribe_tally(_socket), do: :ok

  defp entry_kind_state(entry_kinds, entry) do
    case {bill_entry?(entry), entry_extension(entry), entry.done?,
          Map.get(entry_kinds, entry.ref)} do
      {true, _extension, _done?, {:ok, kind}} -> {:bill, kind}
      {true, _extension, _done?, _state} -> {:bill, nil}
      {false, ".json", false, _state} -> :identifying
      {false, ".json", true, {:ok, kind}} -> {:identified, kind}
      {false, ".json", true, {:error, reason}} -> {:error, reason}
      {false, ".json", true, nil} -> :identifying
    end
  end

  defp portal_error_label(:invalid_json), do: "This is not valid JSON"
  defp portal_error_label(:ambiguous_structure), do: "This matches more than one portal format"
  defp portal_error_label(:unreadable), do: "Nila could not read this back after it uploaded"
  defp portal_error_label(_reason), do: "This is not a recognized GST portal file"

  defp kind_title("sales"), do: "Sales bills"
  defp kind_title("purchase"), do: "Purchase bills"
  defp kind_title("gstr2b"), do: "GSTR-2B"
  defp kind_title("filed_gstr1"), do: "Filed GSTR-1"

  # A read that lost pages to a provider error still derives a month, so it is
  # `:done` — but a green check over a month that is missing a bill is the one
  # thing this screen must not say. The pages are named here, next to the button
  # that sends the operator to them.
  defp partial?(%{status: :done, unaccounted: [_ | _]}), do: true
  defp partial?(_job), do: false

  defp page_list([page]), do: "Page #{page}"
  defp page_list(pages), do: "Pages #{Enum.join(pages, ", ")}"

  defp retry_message("all"), do: "The document did not come back. Asking again."
  defp retry_message(pages), do: "Pages #{pages} did not come back. Asking again."

  defp job_label(%{worker_retry: %{state: :waiting, attempt: attempt, max_attempts: max}}),
    do: "Processing interrupted — retrying (#{attempt} of #{max})"

  defp job_label(%{worker_retry: %{state: :running, attempt: attempt, max_attempts: max}}),
    do: "Reading again — attempt #{attempt} of #{max}"

  defp job_label(%{status: :extracting, progress: %{stage: stage}})
       when stage in [:transcribing, :segmenting],
       do: "Preparing the document"

  defp job_label(%{status: :done, bill_count: count, unaccounted: []})
       when is_integer(count),
       do: "Done — #{count} #{pluralize(count, "bill")} added"

  defp job_label(job) do
    if partial?(job), do: "Read, but not all of it", else: status_label(job.status)
  end

  defp job_variant(%{worker_retry: %{}}), do: "warning"

  defp job_variant(job) do
    if partial?(job), do: "warning", else: status_variant(job.status)
  end

  defp status_label(:queued), do: "Queued"
  defp status_label(:extracting), do: "Reading the bills"
  defp status_label(:deriving), do: "Checking the result"
  defp status_label(:reconciling), do: "Checking the result"
  defp status_label(:done), do: "Done"

  defp status_label(:held),
    do: "Held — this month's return is already signed. Open the month to have a senior reopen it."

  defp status_label(:needs_confirmation),
    do: "Read, but it doesn't look like this month's — open the month to sort it out"

  defp status_label(:after_filing),
    do: "This month is already filed — bring this into the current month instead"

  defp status_label(:failed), do: "Failed — check the file and bring it in again"
  defp status_label(_stage), do: "Working"

  defp status_variant(:done), do: "success"
  defp status_variant(:failed), do: "error"
  defp status_variant(:held), do: "warning"
  defp status_variant(:needs_confirmation), do: "warning"
  defp status_variant(:after_filing), do: "info"
  defp status_variant(_status), do: "neutral"

  @settled [:done, :failed, :held, :after_filing, :needs_confirmation]

  defp working?(jobs) do
    Enum.any?(jobs, fn {_id, job} -> job.status not in @settled end)
  end

  defp any_done?(jobs) do
    Enum.any?(jobs, fn {_id, job} -> job.status == :done end)
  end

  defp spinning?(status), do: status not in @settled

  # The row spinner is the sole progress signal while useful accounting work is
  # still unknown. Page labelling is deliberately folded into preparation: a CA
  # cares how many bills are ready, not how many classifier calls have returned.
  # The bar appears only once the bill count is known, when zero is a real value.
  defp progress_bar?(%{stage: stage}), do: stage in [:reading, :checking]

  defp progress_value(%{done: done}), do: done

  defp progress_max(%{total: total}), do: total

  # The provider pipeline has more stages than the customer journey. Expose one
  # preparation phase, then progress in bills — the artifact the CA brought in
  # and the only unit on which they can act.
  defp progress_caption(%{stage: :transcribing}), do: "reading the scan"

  defp progress_caption(%{stage: :segmenting, page_count: count}),
    do: "#{count} #{pluralize(count, "page")} received"

  defp progress_caption(%{stage: :reading, done: 0, total: total}),
    do: "#{total} #{pluralize(total, "bill")} found — starting to read"

  defp progress_caption(%{stage: :reading, done: done, total: total}),
    do: "#{done} of #{total} #{pluralize(total, "bill")} read"

  defp progress_caption(%{stage: :checking, total: total}),
    do: "#{total} of #{total} #{pluralize(total, "bill")} read"

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  defp client_name(clients, client_id) do
    Enum.find_value(clients, fn {name, id} ->
      if to_string(id) == to_string(client_id), do: name
    end)
  end

  @impl true
  def render(%{sales_intake?: true} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="sales-bills-page" class="space-y-section mx-auto max-w-2xl">
        <.page_header title="Sales bills to Tally" />

        <.card :if={@tally_state == :connect and @jobs == %{}} id="sales-bills-connect-tally">
          <div class="space-y-block">
            <p class="text-base-content text-h4 font-semibold">Connect TallyPrime</p>
            <.button navigate={~p"/settings/connectors"} id="sales-bills-connect-tally-button">
              Connect Tally
            </.button>
          </div>
        </.card>

        <.card
          :if={@tally_state == :start_connector and @jobs == %{}}
          id="sales-bills-start-connector"
        >
          <p class="text-base-content text-h4 font-semibold">
            Start Nila Connector on this computer
          </p>
        </.card>

        <.card
          :if={@tally_state == :open_company and @jobs == %{}}
          id="sales-bills-open-company"
        >
          <p class="text-base-content text-h4 font-semibold">Open the company in TallyPrime</p>
        </.card>

        <.card
          :if={@tally_state == :unavailable and @jobs == %{}}
          id="sales-bills-tally-unavailable"
        >
          <p class="text-base-content text-h4 font-semibold">
            Nila could not use the open Tally company
          </p>
        </.card>

        <.card :if={
          (match?({:ready, _name}, @tally_state) or @tally_state == :choose_company) and @jobs == %{}
        }>
          <.form
            for={@form}
            id="sales-bills-form"
            phx-change="validate"
            phx-submit="submit"
            class="space-y-block"
          >
            <p
              :if={match?({:ready, _name}, @tally_state)}
              class="text-base-content text-ui font-semibold"
            >
              {elem(@tally_state, 1)} is open in TallyPrime
            </p>
            <.input
              :if={match?({:ready, _name}, @tally_state)}
              field={@form[:client_id]}
              type="hidden"
            />
            <.input
              :if={@tally_state == :choose_company}
              field={@form[:client_id]}
              type="select"
              label="Tally company"
              prompt="Select a company"
              options={@clients}
            />
            <.file_drop
              id="sales-bills-documents"
              upload={@uploads.documents}
              hint="PDF or image · up to 50 files"
              on_cancel="cancel-upload"
            />

            <p :if={@error} id="sales-bills-error" class="nila-upload-error text-ui">
              {@error}
            </p>

            <.button type="submit" id="sales-bills-submit" full_width>
              Prepare Tally vouchers
            </.button>
          </.form>
        </.card>

        <.card :if={@jobs != %{}} id="sales-bills-progress">
          <div class="flex items-center gap-3">
            <.spinner tone="accent" label="Preparing sales vouchers" />
            <p class="text-base-content text-h4 font-semibold">Preparing sales vouchers</p>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="gst-upload-page" class="space-y-section mx-auto max-w-2xl">
        <.page_header eyebrow="Intake" title="Bring in documents">
          Drop whatever arrived — sales bills, purchase bills, the 2B, or any mix.
          Nila extracts it, adds it to the month's pile, and reworks the month.
        </.page_header>

        <.card
          :if={@clients == [] and @jobs == %{}}
          id="gst-upload-empty"
          padding="roomy"
          class="text-center"
        >
          <div class="space-y-block">
            <h2 class="text-base-content text-h4 font-semibold">No clients yet</h2>
            <.button navigate={~p"/clients/new"} id="gst-upload-add-first-client">
              <.icon name="hero-plus" class="size-4" /> Add your first client
            </.button>
          </div>
        </.card>

        <.card :if={@clients != [] and @jobs == %{}}>
          <.form
            for={@form}
            id="gst-upload-form"
            phx-change="validate"
            phx-submit="submit"
            class="space-y-block"
          >
            <div>
              <.input
                field={@form[:client_id]}
                type="select"
                label="Client"
                prompt="Select a client"
                options={@clients}
              />
              <p class="text-ink-muted text-ui mt-1">
                Client not listed?
                <.link
                  navigate={~p"/clients/new"}
                  id="gst-upload-add-client"
                  class="text-moon font-semibold"
                >
                  Add one
                </.link>
              </p>
            </div>

            <.input
              field={@form[:period]}
              type="select"
              label="Period"
              options={@period_options}
            />

            <.file_drop
              id="gst-upload-documents"
              upload={@uploads.documents}
              label="Documents"
              hint="PDF or image bills, or GST portal JSON · up to 10 files"
              on_cancel="cancel-upload"
            >
              <:entry :let={entry}>
                <%= case entry_kind_state(@entry_kinds, entry) do %>
                  <% {:bill, selected} -> %>
                    <div
                      id={"gst-upload-kind-#{entry.ref}"}
                      class="flex flex-wrap items-center justify-between gap-2"
                    >
                      <p class="text-ink-muted text-ui">Which side are these bills for?</p>
                      <div class="flex items-center gap-1.5">
                        <.button
                          type="button"
                          id={"gst-upload-sales-#{entry.ref}"}
                          phx-click="choose-kind"
                          phx-value-ref={entry.ref}
                          phx-value-kind="sales"
                          variant={if(selected == "sales", do: "primary", else: "outline")}
                          size="xs"
                        >
                          Sales
                        </.button>
                        <.button
                          type="button"
                          id={"gst-upload-purchase-#{entry.ref}"}
                          phx-click="choose-kind"
                          phx-value-ref={entry.ref}
                          phx-value-kind="purchase"
                          variant={if(selected == "purchase", do: "primary", else: "outline")}
                          size="xs"
                        >
                          Purchase
                        </.button>
                      </div>
                    </div>
                  <% :identifying -> %>
                    <p class="text-ink-muted text-ui">Identifying the portal file…</p>
                  <% {:identified, kind} -> %>
                    <div
                      id={"gst-upload-kind-#{entry.ref}"}
                      class="nila-upload-identification text-ui flex items-center gap-1.5"
                      data-kind="success"
                    >
                      <.icon name="hero-check-circle" class="size-4" />
                      {kind_title(kind)} · detected from the portal structure
                    </div>
                  <% {:error, reason} -> %>
                    <div
                      id={"gst-upload-kind-#{entry.ref}"}
                      class="nila-upload-identification text-ui flex items-center gap-1.5"
                      data-kind="error"
                    >
                      <.icon name="hero-exclamation-circle" class="size-4" />
                      {portal_error_label(reason)}
                    </div>
                <% end %>
              </:entry>
            </.file_drop>

            <p :if={@error} id="gst-upload-error" class="nila-upload-error text-ui">
              {@error}
            </p>

            <.button type="submit" id="gst-upload-submit" full_width>
              <.icon name="hero-arrow-up-tray" class="size-4" /> Bring it in
            </.button>
          </.form>
        </.card>

        <.card :if={@jobs != %{}} id="gst-upload-progress" class="space-y-block">
          <div
            :if={@pending}
            id="gst-upload-progress-header"
            class="border-base-300 pb-block flex items-baseline justify-between gap-4 border-b"
          >
            <p class="text-base-content text-h4 truncate font-semibold">
              {client_name(@clients, @pending.client_id) || "This client"}
            </p>
            <p class="text-ink-subtle text-ui shrink-0">{period_label(@pending.period)}</p>
          </div>

          <div
            :for={{dump_id, job} <- Enum.sort(@jobs)}
            id={"gst-dump-#{dump_id}"}
            class="space-y-related"
          >
            <div class="flex items-start gap-3">
              <div :if={spinning?(job.status)} class="mt-0.5 shrink-0">
                <.spinner tone="accent" label="Processing" />
              </div>
              <.icon
                :if={job.status == :done and not partial?(job)}
                name="hero-check-circle"
                class="text-success mt-0.5 size-5 shrink-0"
              />
              <.icon
                :if={partial?(job)}
                name="hero-exclamation-triangle"
                class="text-warning mt-0.5 size-5 shrink-0"
              />
              <.icon
                :if={job.status == :failed}
                name="hero-exclamation-circle"
                class="text-error mt-0.5 size-5 shrink-0"
              />
              <.icon
                :if={job.status == :held}
                name="hero-pause-circle"
                class="text-warning mt-0.5 size-5 shrink-0"
              />
              <.icon
                :if={job.status == :needs_confirmation}
                name="hero-question-mark-circle"
                class="text-warning mt-0.5 size-5 shrink-0"
              />
              <.icon
                :if={job.status == :after_filing}
                name="hero-information-circle"
                class="text-info mt-0.5 size-5 shrink-0"
              />
              <div class="min-w-0 flex-1">
                <p class="text-base-content text-ui font-medium">{kind_title(job.kind)}</p>
                <p class="nila-upload-job-label text-ui" data-kind={job_variant(job)}>
                  {job_label(job)}
                </p>
                <p :if={partial?(job)} class="text-body text-ink-subtle">
                  {page_list(job.unaccounted)} produced no bill. Open the month and check the original.
                </p>
                <.link
                  :if={job.status in [:held, :needs_confirmation]}
                  navigate={~p"/gst/#{job.client_id}/#{job.period}"}
                  id={"gst-dump-open-month-#{dump_id}"}
                  class="text-moon text-ui font-semibold"
                >
                  Open the month
                </.link>
                <.link
                  :if={job.status == :after_filing}
                  navigate={
                    ~p"/gst/upload?client_id=#{job.client_id}&period=#{Calendar.closeable_period(Date.utc_today())}"
                  }
                  id={"gst-dump-open-period-#{dump_id}"}
                  class="text-moon text-ui font-semibold"
                >
                  Bring it into the open month →
                </.link>
                <div :if={job.status == :failed} class="mt-related">
                  <.button
                    id={"gst-dump-try-again-#{dump_id}"}
                    phx-click="try-again"
                    variant="soft"
                    size="xs"
                  >
                    <.icon name="hero-arrow-path" class="size-4" /> Try again
                  </.button>
                </div>
              </div>
            </div>

            <div :if={job.progress} id={"gst-dump-progress-#{dump_id}"} class="space-y-1.5 pl-8">
              <.progress_bar
                :if={progress_bar?(job.progress)}
                value={progress_value(job.progress)}
                max={progress_max(job.progress)}
              />
              <p class="text-ink-subtle text-ui tabular-nums">
                {progress_caption(job.progress)}
              </p>
              <p :if={job.retrying} class="nila-upload-retry text-ui">
                {retry_message(job.retrying)}
              </p>
            </div>
          </div>

          <p :if={working?(@jobs)} class="text-ink-muted text-ui">
            You can leave this open — each pile lands on the month as it finishes.
          </p>

          <.button
            :if={not working?(@jobs) and any_done?(@jobs)}
            id="gst-upload-open-month"
            phx-click="open-month"
            variant="primary"
            full_width
            autofocus
          >
            Open the month
          </.button>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
