defmodule NilaWeb.Gst.UploadLive do
  use NilaWeb, :live_view

  @moduledoc """
  Bring in documents — the intake action. Documents arrive as sales bills, a
  shoebox of purchases, portal downloads, and stragglers after the chase. The
  operator drops the files first: bill PDFs are then labelled Sales or Purchase,
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
  alias NilaWeb.Gst.PeriodOptions

  # Mistral's own document limit. Base64's 4/3 expansion would put anything
  # over ~37.5 MB past this ceiling, so the segmented pipeline uploads large
  # packets once instead of inlining them. The drop
  # zone is where a too-large pile should be refused — not a minute later, from
  # inside extraction, as a provider size error.
  @max_pdf_bytes 50_000_000
  @max_json_bytes 20_000_000
  @max_upload_entries 10

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: subscribe(socket)

    prefilled = prefill(socket, params)

    socket =
      socket
      |> assign(:page_title, "Bring in documents")
      |> assign(:clients, list_clients(socket))
      |> assign(:form, to_form(prefilled, as: :intake))
      |> assign_period_options(prefilled["client_id"])
      |> assign(:entry_kinds, %{})
      |> assign(:jobs, %{})
      |> assign(:pending, nil)
      |> allow_upload(:documents,
        accept: ~w(.pdf .json),
        max_entries: @max_upload_entries,
        max_file_size: @max_pdf_bytes,
        auto_upload: true,
        progress: &handle_upload_progress/3,
        validator: &validate_document_entry/1
      )

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
    {:noreply,
     socket
     |> assign(:form, to_form(params, as: :intake))
     |> assign_period_options(params["client_id"])}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> cancel_upload(:documents, ref)
     |> assign(:entry_kinds, Map.delete(socket.assigns.entry_kinds, ref))}
  end

  def handle_event("choose-kind", %{"ref" => ref, "kind" => kind}, socket)
      when kind in ~w(sales purchase) do
    entry = Enum.find(socket.assigns.uploads.documents.entries, &(&1.ref == ref))

    entry_kinds =
      if entry && entry_extension(entry) == ".pdf" do
        Map.put(socket.assigns.entry_kinds, ref, {:ok, kind})
      else
        socket.assigns.entry_kinds
      end

    {:noreply, assign(socket, :entry_kinds, entry_kinds)}
  end

  def handle_event("choose-kind", _params, socket), do: {:noreply, socket}

  def handle_event("submit", %{"intake" => params}, socket) do
    org = socket.assigns.current_scope.current_org

    with {:ok, client_id} <- fetch_client(org, params["client_id"]),
         {:ok, period} <- fetch_period(params["period"]),
         {:ok, entry_kinds} <- ready_entries(socket) do
      jobs =
        socket
        |> create_dumps(org.id, client_id, period, entry_kinds)
        |> Map.new(fn dump ->
          {dump.id,
           %{
             kind: dump.kind,
             status: :queued,
             progress: nil,
             retrying: nil,
             client_id: client_id,
             period: period
           }}
        end)

      {:noreply,
       socket
       |> assign(:entry_kinds, %{})
       |> assign(:jobs, jobs)
       |> assign(:error, nil)
       |> assign(:pending, %{client_id: client_id, period: period})}
    else
      {:error, message} ->
        {:noreply, assign(socket, :error, message)}
    end
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
     |> assign(:jobs, %{})
     |> assign(
       :form,
       to_form(%{"client_id" => to_string(client_id), "period" => period}, as: :intake)
     )
     |> assign_period_options(client_id)}
  end

  defp handle_upload_progress(:documents, %{done?: true} = entry, socket) do
    entry_kinds =
      if entry_extension(entry) == ".json" do
        classification =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:postpone, path |> File.read!() |> PortalDocument.classify()}
          end)

        Map.put(socket.assigns.entry_kinds, entry.ref, classification)
      else
        socket.assigns.entry_kinds
      end

    {:noreply, assign(socket, :entry_kinds, entry_kinds)}
  end

  defp handle_upload_progress(:documents, _entry, socket), do: {:noreply, socket}

  defp validate_document_entry(entry) do
    if entry_extension(entry) == ".json" and entry.client_size > @max_json_bytes,
      do: {:error, :json_too_large},
      else: :ok
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
    case {entry_extension(entry), Map.get(entry_kinds, entry.ref)} do
      {".pdf", {:ok, kind}} when kind in ~w(sales purchase) -> true
      {".json", {:ok, kind}} when kind in ~w(gstr2b filed_gstr1) -> true
      _ -> false
    end
  end

  defp entry_readiness_error(entry, entry_kinds) do
    case {entry_extension(entry), Map.get(entry_kinds, entry.ref)} do
      {".pdf", _state} ->
        "Choose Sales or Purchase for #{entry.client_name}."

      {".json", {:error, :invalid_json}} ->
        "#{entry.client_name} is not valid JSON."

      {".json", {:error, :ambiguous_structure}} ->
        "#{entry.client_name} matches more than one portal format. Remove it and check the download."

      {".json", nil} ->
        "Nila could not finish identifying #{entry.client_name}. Remove it and try again."

      {".json", _state} ->
        "#{entry.client_name} is not a GSTR-2B or filed GSTR-1 portal file."
    end
  end

  defp create_dumps(socket, org_id, client_id, period, entry_kinds) do
    scope = socket.assigns.current_scope

    socket
    |> consume_uploaded_entries(:documents, fn %{path: path}, entry ->
      {:ok, kind} = Map.fetch!(entry_kinds, entry.ref)
      bytes = File.read!(path)
      ext = entry_extension(entry)

      key =
        "orgs/#{org_id}/clients/#{client_id}/#{period}/dumps/#{Ecto.UUID.generate()}/original#{ext}"

      {:ok, _} = Storage.put(key, bytes, content_type: upload_content_type(kind))
      {:ok, {kind, key}}
    end)
    |> Enum.map(fn {kind, key} ->
      {:ok, dump} =
        Dumps.record(
          %{org_id: org_id, client_id: client_id, brought_in_by_id: scope.user.id},
          %{period: period, kind: kind, file_keys: [key]}
        )

      {:ok, _job} = Oban.insert(DumpWorker.new(%{dump_id: dump.id}))
      dump
    end)
  end

  defp entry_extension(entry),
    do: entry.client_name |> Path.extname() |> String.downcase()

  @impl true
  def handle_info({:gst_dump_progress, dump_id, _client_id, _period, _kind, message}, socket) do
    case socket.assigns.jobs do
      %{^dump_id => job} = jobs ->
        {:noreply, assign(socket, :jobs, Map.put(jobs, dump_id, apply_progress(job, message)))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp apply_progress(job, {:done, _client_id, _period}), do: %{job | status: :done}
  defp apply_progress(job, {:failed, _reason}), do: %{job | status: :failed}
  defp apply_progress(job, :held), do: %{job | status: :held}

  defp apply_progress(job, {:extracting, window}) when is_map(window),
    do: %{job | status: :extracting, progress: window}

  # A resent window costs another provider round-trip, so the bar sits still for
  # ~40s while it happens. Saying so is the difference between a slow read and a
  # screen that looks hung — the same reason the ledger refuses silence.
  defp apply_progress(job, {:extracting_retry, pages}),
    do: %{job | status: :extracting, retrying: pages}

  # Past extraction the window counts are stale — derivation is a different unit
  # of work, and a bar frozen at "48 of 57 pages" would read as stuck.
  defp apply_progress(job, stage) when is_atom(stage),
    do: %{job | status: stage, progress: nil, retrying: nil}

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

  defp upload_content_type(kind) when kind in ~w(gstr2b filed_gstr1), do: "application/json"
  defp upload_content_type(_kind), do: "application/pdf"

  defp entry_kind_state(entry_kinds, entry) do
    case {entry_extension(entry), entry.done?, Map.get(entry_kinds, entry.ref)} do
      {".pdf", _done?, {:ok, kind}} -> {:pdf, kind}
      {".pdf", _done?, _state} -> {:pdf, nil}
      {".json", false, _state} -> :identifying
      {".json", true, {:ok, kind}} -> {:identified, kind}
      {".json", true, {:error, reason}} -> {:error, reason}
      {".json", true, nil} -> :identifying
    end
  end

  defp portal_error_label(:invalid_json), do: "This is not valid JSON"
  defp portal_error_label(:ambiguous_structure), do: "This matches more than one portal format"
  defp portal_error_label(_reason), do: "This is not a recognized GST portal file"

  defp kind_title("sales"), do: "Sales bills"
  defp kind_title("purchase"), do: "Purchase bills"
  defp kind_title("gstr2b"), do: "GSTR-2B"
  defp kind_title("filed_gstr1"), do: "Filed GSTR-1"

  defp job_label(:queued), do: "Queued"
  defp job_label(:extracting), do: "Reading the bills"
  defp job_label(:deriving), do: "Deriving the GSTR-1"
  defp job_label(:reconciling), do: "Reconciling against 2B"
  defp job_label(:done), do: "Done"

  defp job_label(:held),
    do: "Held — this month's return is already signed. Open the month to have a senior reopen it."

  defp job_label(:needs_confirmation),
    do: "Read, but it doesn't look like this month's — open the month to sort it out"

  defp job_label(:after_filing),
    do: "This month is already filed — bring this into the current month instead"

  defp job_label(:failed), do: "Failed — check the file and bring it in again"
  defp job_label(_stage), do: "Working"

  defp job_variant(:done), do: "success"
  defp job_variant(:failed), do: "error"
  defp job_variant(:held), do: "warning"
  defp job_variant(:needs_confirmation), do: "warning"
  defp job_variant(:after_filing), do: "info"
  defp job_variant(_status), do: "neutral"

  @settled [:done, :failed, :held, :after_filing, :needs_confirmation]

  defp working?(jobs) do
    Enum.any?(jobs, fn {_id, job} -> job.status not in @settled end)
  end

  defp any_done?(jobs) do
    Enum.any?(jobs, fn {_id, job} -> job.status == :done end)
  end

  defp spinning?(status), do: status not in @settled

  # Pages are the unit the operator can see in their own PDF, so the bar counts
  # pages when the page count is known and falls back to windows when `pdfinfo`
  # could not read the document. Nothing landed yet omits `value` entirely,
  # which is daisyUI's indeterminate bar — the honest render for "started, no
  # ground covered", and the thing a static empty bar gets wrong.
  defp progress_value(%{page_count: page_count, pages_done: 0}) when is_integer(page_count),
    do: nil

  defp progress_value(%{page_count: page_count, pages_done: pages_done})
       when is_integer(page_count),
       do: pages_done

  defp progress_value(%{done: 0}), do: nil
  defp progress_value(%{done: done}), do: done

  defp progress_max(%{page_count: page_count}) when is_integer(page_count), do: page_count
  defp progress_max(%{total: total}), do: total

  # The read has three stages and the honest unit changes between them: the scan
  # is one call, the packet is then labelled page by page, and only then is each
  # bill read. Saying "pages" while bills are being read would stall a bar that
  # is in fact moving.
  defp progress_caption(%{stage: :transcribing}), do: "reading the scan"

  defp progress_caption(%{stage: :reading, done: 0, total: total}),
    do: "#{total} #{pluralize(total, "bill")} to read"

  defp progress_caption(%{stage: :reading, done: done, total: total}),
    do: "#{done} of #{total} #{pluralize(total, "bill")} read"

  # Before the first window lands the count is the *size of the job*, which is
  # the reassuring number ("of course a 57-page packet takes a minute"), not a
  # zero.
  defp progress_caption(%{page_count: count, pages_done: 0}) when is_integer(count),
    do: "#{count} #{pluralize(count, "page")} to read"

  defp progress_caption(%{page_count: count, pages_done: done}) when is_integer(count),
    do: "#{done} of #{count} #{pluralize(count, "page")} read"

  defp progress_caption(%{done: 0, total: total}),
    do: "#{total} #{pluralize(total, "part")} to read"

  defp progress_caption(%{done: done, total: total}),
    do: "#{done} of #{total} #{pluralize(total, "part")} read"

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  defp client_name(clients, client_id) do
    Enum.find_value(clients, fn {name, id} ->
      if to_string(id) == to_string(client_id), do: name
    end)
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

        <.card :if={@clients == [] and @jobs == %{}} id="gst-upload-empty" class="py-12 text-center">
          <div class="space-y-block">
            <h2 class="text-base-content text-h4 font-semibold">No clients yet</h2>
            <.button navigate={~p"/clients/new"} id="gst-upload-add-first-client">
              Add your first client
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
              <p class="text-ink-muted text-meta mt-1">
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
              hint="PDF bills or GST portal JSON · up to 10 files"
              on_cancel="cancel-upload"
            >
              <:entry :let={entry}>
                <%= case entry_kind_state(@entry_kinds, entry) do %>
                  <% {:pdf, selected} -> %>
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
                    <p class="text-ink-muted text-meta">Identifying the portal file…</p>
                  <% {:identified, kind} -> %>
                    <div
                      id={"gst-upload-kind-#{entry.ref}"}
                      class="text-meta text-success flex items-center gap-1.5"
                    >
                      <.icon name="hero-check-circle" class="size-4" />
                      {kind_title(kind)} · detected from the portal structure
                    </div>
                  <% {:error, reason} -> %>
                    <div
                      id={"gst-upload-kind-#{entry.ref}"}
                      class="text-error text-meta flex items-center gap-1.5"
                    >
                      <.icon name="hero-exclamation-circle" class="size-4" />
                      {portal_error_label(reason)}
                    </div>
                <% end %>
              </:entry>
            </.file_drop>

            <p :if={@error} id="gst-upload-error" class="text-error text-ui">
              {@error}
            </p>

            <.button type="submit" id="gst-upload-submit" class="w-full">
              Bring it in
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
            <p class="text-ink-subtle text-meta shrink-0">{period_label(@pending.period)}</p>
          </div>

          <div
            :for={{dump_id, job} <- Enum.sort(@jobs)}
            id={"gst-dump-#{dump_id}"}
            class="space-y-related"
          >
            <div class="flex items-start gap-3">
              <span
                :if={spinning?(job.status)}
                class="loading loading-sm loading-spinner text-primary mt-0.5 shrink-0"
              ></span>
              <.icon
                :if={job.status == :done}
                name="hero-check-circle"
                class="text-success mt-0.5 size-5 shrink-0"
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
                <p class={["text-meta", "text-#{job_variant(job.status)}"]}>
                  {job_label(job.status)}
                </p>
                <.link
                  :if={job.status in [:held, :needs_confirmation]}
                  navigate={~p"/gst/#{job.client_id}/#{job.period}"}
                  id={"gst-dump-open-month-#{dump_id}"}
                  class="text-meta text-moon font-semibold"
                >
                  Open the month
                </.link>
                <.link
                  :if={job.status == :after_filing}
                  navigate={
                    ~p"/gst/upload?client_id=#{job.client_id}&period=#{Calendar.closeable_period(Date.utc_today())}"
                  }
                  id={"gst-dump-open-period-#{dump_id}"}
                  class="text-meta text-moon font-semibold"
                >
                  Bring it into the open month →
                </.link>
                <.button
                  :if={job.status == :failed}
                  id={"gst-dump-try-again-#{dump_id}"}
                  phx-click="try-again"
                  variant="soft"
                  size="xs"
                  class="mt-related"
                >
                  Try again
                </.button>
              </div>
            </div>

            <div :if={job.progress} id={"gst-dump-progress-#{dump_id}"} class="space-y-1.5 pl-8">
              <progress
                class="progress progress-primary block h-1.5 w-full"
                value={progress_value(job.progress)}
                max={progress_max(job.progress)}
              ></progress>
              <p class="text-ink-subtle text-meta tabular-nums">
                {progress_caption(job.progress)}
              </p>
              <p :if={job.retrying} class="text-meta text-warning">
                Pages {job.retrying} did not come back. Asking again.
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
            class="w-full"
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
