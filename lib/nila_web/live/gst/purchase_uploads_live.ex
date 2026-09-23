defmodule NilaWeb.Gst.PurchaseUploadsLive do
  use NilaWeb, :live_view
  alias Nila.Gst.Intake.{Dumps, Progress}
  alias NilaWeb.Components.Gst.PeriodHeader
  alias NilaWeb.Gst.PurchaseWorkspace, as: Workspace

  @impl true
  def mount(%{"client_id" => client_id, "period" => period}, _, socket) do
    with {:ok, client} <-
           Nila.Clients.get_client(socket.assigns.current_scope.current_org.id, client_id),
         {:ok, date} <- Date.from_iso8601(period <> "-01") do
      if connected?(socket), do: Progress.subscribe(socket.assigns.current_scope.current_org.id)

      {:ok,
       socket
       |> assign(
         client: client,
         period: period,
         page_title: "Purchase uploads",
         period_label: Calendar.strftime(date, "%B %Y"),
         can_import: Nila.Accounts.Policy.can?(socket.assigns.current_scope, :edit_records),
         filing_picker_year: date.year,
         selected_id: nil,
         selected: nil
       )
       |> reload()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That client or month isn't available.")
         |> push_navigate(to: ~p"/app/clients")}
    end
  end

  @impl true
  def handle_params(params, _, socket) do
    if socket.assigns[:client] do
      {:noreply, socket |> assign(selected_id: params["upload"]) |> select_upload()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("shift-filing-year", %{"direction" => direction}, socket)
      when direction in ~w(previous next) do
    offset = if direction == "previous", do: -1, else: 1

    {:noreply,
     assign(
       socket,
       :filing_picker_year,
       min(Date.utc_today().year, max(1, socket.assigns.filing_picker_year + offset))
     )}
  end

  @impl true
  def handle_info({:gst_dump_progress, _, client_id, period, _, _}, socket) do
    if client_id == socket.assigns.client.id and period == socket.assigns.period,
      do: {:noreply, reload(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp reload(socket) do
    dumps =
      Dumps.list(
        socket.assigns.current_scope.current_org.id,
        socket.assigns.client.id,
        socket.assigns.period
      )
      |> Enum.filter(&(&1.kind == "purchase"))
      |> Enum.reverse()

    socket
    |> assign(dumps: dumps, upload_count: length(dumps))
    |> select_upload()
  end

  defp select_upload(socket) do
    selected = Enum.find(socket.assigns.dumps, &(to_string(&1.id) == socket.assigns.selected_id))
    invoices = if selected, do: selected.invoices, else: []

    rows =
      invoices
      |> Enum.with_index()
      |> Enum.map(fn {invoice, index} -> %{id: index, invoice: invoice} end)

    socket
    |> assign(selected: selected)
    |> stream(:uploads, socket.assigns.dumps, reset: true)
    |> stream(:upload_invoices, rows, reset: true)
  end

  defp filename(dump),
    do: dump.meta["original_name"] || Enum.map_join(dump.file_keys, ", ", &Path.basename/1)

  defp original_label(dump, index),
    do:
      if(length(dump.file_keys) == 1,
        do: "Download original",
        else: "Download original #{index + 1}"
      )

  defp outcome(%{status: "extracted"}), do: "Imported"
  defp outcome(%{status: "received"}), do: "Waiting to process"
  defp outcome(%{status: "extracting"}), do: "Processing"
  defp outcome(%{status: "failed"}), do: "Processing failed"
  defp outcome(%{status: "held"}), do: "Held after sign-off"
  defp outcome(%{status: "after_filing"}), do: "Arrived after filing"
  defp outcome(%{status: "needs_confirmation"}), do: "Needs confirmation"
  defp outcome(%{status: "discarded"}), do: "Discarded"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_client={@client}
      current_path={@current_path}
    >
      <div id="purchase-uploads-page" class="space-y-block mx-auto w-full max-w-[1400px]">
        <PeriodHeader.period_header
          client={@client}
          period={@period}
          picker_year={@filing_picker_year}
          section="Purchases & ITC"
          path_for_period={fn period -> ~p"/gst/#{@client.id}/#{period}/purchases/uploads" end}
        />
        <.text_link id="purchase-uploads-back" navigate={~p"/app/gst/#{@client.id}/#{@period}/purchases"}>← Purchases &amp; ITC overview</.text_link>
        <.text_link
          :if={@selected}
          id="purchase-upload-back"
          patch={~p"/gst/#{@client.id}/#{@period}/purchases/uploads"}
        >← All uploads</.text_link>
        <.page_header :if={!@selected} title="Purchase uploads">
          <:actions>
            <.button
              id="purchase-uploads-import"
              navigate={~p"/gst/#{@client.id}/#{@period}/purchases/import-excel"}
              disabled={!@can_import}
              title={if !@can_import, do: "You don't have permission to import purchases."}
            >Import purchase Excel</.button>
          </:actions>
        </.page_header>

        <p :if={@upload_count == 0} id="purchase-uploads-empty" class="text-ink-muted text-ui">
          No purchase files uploaded for {@period_label}.
        </p>

        <.data_table
          :if={@upload_count > 0 && !@selected}
          id="purchase-uploads"
          rows={@streams.uploads}
          mode="review"
        >
          <:col :let={dump} label="File" row_header>
            <p class="font-medium break-all">{filename(dump)}</p>

            <.context_text :if={dump.meta["excel_sheet"]}>
              Sheet: {dump.meta["excel_sheet"]}
            </.context_text>
          </:col>

          <:col :let={dump} label="Uploaded">
            <p>{Calendar.strftime(dump.inserted_at, "%d %b %Y · %H:%M UTC")}</p>

            <.context_text :if={dump.brought_in_by}>{dump.brought_in_by.email}</.context_text>
          </:col>

          <:col :let={dump} label="Result">
            <p>{outcome(dump)}</p>

            <p :if={dump.status == "extracted"}>
              {length(dump.invoices)} {if length(dump.invoices) == 1, do: "invoice", else: "invoices"} imported
            </p>

            <p :if={dump.status != "extracted" && dump.invoices != []}>
              {length(dump.invoices)} {if length(dump.invoices) == 1, do: "invoice", else: "invoices"} read
            </p>

            <p :if={dump.error} class="text-ink-muted">{dump.error}</p>

            <details
              :if={dump.meta["excel_excluded_rows"] not in [nil, []]}
              id={"purchase-upload-excluded-#{dump.id}"}
            >
              <summary>{length(dump.meta["excel_excluded_rows"])} spreadsheet rows left out</summary>

              <p>Excluded during import: rows {Enum.join(dump.meta["excel_excluded_rows"], ", ")}.</p>
            </details>

            <p :if={dump.meta["excel_other_sheets"] not in [nil, []]} class="text-ink-muted">
              Other sheets not imported: {Enum.join(dump.meta["excel_other_sheets"], ", ")}
            </p>

            <.text_link
              :if={dump.status in ~w(held after_filing needs_confirmation)}
              navigate={~p"/app/gst/#{@client.id}/#{@period}/purchases"}
            >Resolve on overview</.text_link>
          </:col>

          <:col :let={dump} label="Actions">
            <div class="space-y-related">
              <.text_link
                :if={dump.invoices != []}
                id={"purchase-upload-open-#{dump.id}"}
                patch={~p"/gst/#{@client.id}/#{@period}/purchases/uploads?upload=#{dump.id}"}
              >View invoices</.text_link>
              <div :for={{_, index} <- Enum.with_index(dump.file_keys)}>
                <.text_link href={~p"/gst/#{@client.id}/#{@period}/original/#{dump.id}/#{index}"}>{original_label(
                  dump,
                  index
                )}</.text_link>
              </div>
            </div>
          </:col>
        </.data_table>

        <p :if={@selected_id && !@selected} id="purchase-upload-unavailable" class="text-ui">
          That upload isn't available in this month.
        </p>

        <section :if={@selected} id="purchase-upload-detail" class="space-y-block">
          <.page_header title="Uploaded invoices">
            {filename(@selected)} · {outcome(@selected)}. Source values as imported.
          </.page_header>

          <.data_table id="purchase-upload-invoices" rows={@streams.upload_invoices} mode="scan">
            <:col :let={row} label="Invoice" row_header>{row.invoice["invoice_number"]}</:col>

            <:col :let={row} label="Supplier">{row.invoice["vendor_name"]}</:col>

            <:col :let={row} label="GSTIN">{row.invoice["vendor_gstin"]}</:col>

            <:col :let={row} label="Date">{row.invoice["invoice_date"]}</:col>

            <:col :let={row} label="Taxable value" align="right">
              {Workspace.money(row.invoice["taxable_paise"] || 0)}
            </:col>

            <:col :let={row} label="GST" align="right">
              {Workspace.money(Workspace.source_tax(row.invoice))}
            </:col>
          </.data_table>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
