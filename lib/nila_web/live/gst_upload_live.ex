defmodule NilaWeb.GstUploadLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Gst.ClientMonths
  alias Nila.Gst.MonthWorker
  alias Nila.Storage

  @stage_copy %{
    reading: "Reading your files",
    extracting: "Extracting invoices from the bills — this takes a few minutes",
    assembling: "Assembling invoices from the scanned pages",
    reconciling: "Reconciling against GSTR-2B",
    storing: "Filing the scanned evidence"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: subscribe(socket)

    {:ok,
     socket
     |> assign(:page_title, "Add a month")
     |> assign(:clients, list_clients(socket))
     |> assign(
       :form,
       to_form(%{"client_id" => nil, "period_month" => "", "period_year" => ""}, as: :month)
     )
     |> assign(:status, :idle)
     |> assign(:stage, nil)
     |> assign(:error, nil)
     |> allow_upload(:bills, accept: ~w(.pdf), max_entries: 1, max_file_size: 50_000_000)
     |> allow_upload(:gstr2b, accept: ~w(.json), max_entries: 1, max_file_size: 20_000_000)}
  end

  @impl true
  def handle_event("validate", %{"month" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :month))}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    name = if entry_in?(socket, :bills, ref), do: :bills, else: :gstr2b
    {:noreply, cancel_upload(socket, name, ref)}
  end

  def handle_event("submit", %{"month" => params}, socket) do
    org = socket.assigns.current_scope.current_org

    with {:ok, client_id} <- fetch_client(org, params["client_id"]),
         {:ok, period} <- fetch_period(params["period_year"], params["period_month"]),
         {:ok, pdf_key} <- consume_upload(socket, :bills, org.id, client_id, period, "bills.pdf"),
         {:ok, gstr2b_key} <-
           consume_upload(socket, :gstr2b, org.id, client_id, period, "gstr2b") do
      {:ok, _job} =
        MonthWorker.new(%{
          org_id: org.id,
          client_id: client_id,
          period: period,
          pdf_key: pdf_key,
          gstr2b_key: gstr2b_key
        })
        |> Oban.insert()

      {:noreply,
       socket
       |> assign(:status, :working)
       |> assign(:stage, :reading)
       |> assign(:error, nil)
       |> assign(:pending, %{client_id: client_id, period: period})}
    else
      {:error, message} ->
        {:noreply, assign(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:gst_month_progress, client_id, period, message}, socket) do
    pending = socket.assigns[:pending]

    if pending && pending.client_id == client_id && pending.period == period do
      {:noreply, apply_progress(socket, message)}
    else
      {:noreply, socket}
    end
  end

  defp apply_progress(socket, {:done, client_id, period}) do
    push_navigate(socket, to: ~p"/gst/#{client_id}/#{period}")
  end

  defp apply_progress(socket, {:failed, _reason}) do
    socket
    |> assign(:status, :failed)
    |> assign(:stage, nil)
    |> assign(:error, "Extraction failed. Check the files and try again.")
  end

  defp apply_progress(socket, stage) when is_atom(stage) do
    assign(socket, :stage, stage)
  end

  defp entry_in?(socket, name, ref) do
    Enum.any?(socket.assigns.uploads[name].entries, &(&1.ref == ref))
  end

  defp fetch_client(org, client_id) do
    case org && client_id && Clients.get_client(org.id, client_id) do
      {:ok, client} -> {:ok, client.id}
      _ -> {:error, "Pick a client."}
    end
  end

  defp fetch_period(year, month)
       when is_binary(year) and is_binary(month) and year != "" and month != "" do
    {:ok, "#{year}-#{month}"}
  end

  defp fetch_period(_year, _month), do: {:error, "Pick a month and year."}

  defp month_options do
    ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
    |> Enum.with_index(1)
    |> Enum.map(fn {name, n} -> {name, String.pad_leading(to_string(n), 2, "0")} end)
  end

  defp year_options do
    current = Date.utc_today().year
    for y <- current..(current - 3)//-1, do: {to_string(y), to_string(y)}
  end

  defp consume_upload(socket, name, org_id, client_id, period, label) do
    case uploaded_entries(socket, name) do
      {[_entry], []} ->
        [key] =
          consume_uploaded_entries(socket, name, fn %{path: path}, entry ->
            bytes = File.read!(path)
            key = source_key(org_id, client_id, period, label, entry.client_name)
            {:ok, _} = Storage.put(key, bytes)
            {:ok, key}
          end)

        {:ok, key}

      _ ->
        {:error, "Attach both files."}
    end
  end

  defp source_key(org_id, client_id, period, label, client_name) do
    ext = client_name |> Path.extname() |> String.downcase()
    "gst/#{org_id}/#{client_id}/#{period}/source/#{label}#{ext}"
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

  defp stage_label(nil), do: nil
  defp stage_label(stage), do: Map.get(@stage_copy, stage, "Working")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="gst-upload-page" class="mx-auto max-w-2xl space-y-6">
        <.page_header eyebrow="GST" title="Add a month">
          Drop a client's purchase-bills PDF and their GSTR-2B. Nila extracts every
          invoice, reconciles it against 2B, and files the worked month for review.
        </.page_header>

        <.card :if={@status in [:idle, :failed]}>
          <.form for={@form} id="gst-upload-form" phx-change="validate" phx-submit="submit">
            <div class="space-y-5">
              <div>
                <.input
                  field={@form[:client_id]}
                  type="select"
                  label="Client"
                  prompt="Select a client"
                  options={@clients}
                />
                <p class="text-base-content/60 text-fine mt-1">
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

              <div class="grid grid-cols-2 gap-3">
                <.input
                  field={@form[:period_month]}
                  type="select"
                  label="Month"
                  prompt="Month"
                  options={month_options()}
                />
                <.input
                  field={@form[:period_year]}
                  type="select"
                  label="Year"
                  prompt="Year"
                  options={year_options()}
                />
              </div>

              <.file_drop
                id="gst-upload-bills"
                upload={@uploads.bills}
                label="Purchase bills (PDF)"
                hint="One PDF, up to 50 MB"
                on_cancel="cancel-upload"
              />

              <.file_drop
                id="gst-upload-gstr2b"
                upload={@uploads.gstr2b}
                label="GSTR-2B (JSON from the GST portal)"
                hint="The JSON downloaded from the GST portal"
                on_cancel="cancel-upload"
              />

              <p :if={@error} id="gst-upload-error" class="text-error text-small">
                {@error}
              </p>

              <.button type="submit" id="gst-upload-submit" class="w-full">
                Work this month
              </.button>
            </div>
          </.form>
        </.card>

        <.card :if={@status == :working} id="gst-upload-progress" class="space-y-3">
          <div class="flex items-center gap-3">
            <span class="loading loading-sm loading-spinner text-moon"></span>
            <span class="text-base-content text-body">{stage_label(@stage)}</span>
          </div>
          <p class="text-base-content/60 text-small">
            You can leave this open — we'll take you to the worked month when it's ready.
          </p>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
