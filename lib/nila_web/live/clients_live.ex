defmodule NilaWeb.ClientsLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Clients.{Import, ImportXlsx}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Clients")
     |> assign(
       can_import: Nila.Accounts.Policy.can?(socket.assigns.current_scope, :edit_records),
       importing: false,
       import_preview: nil,
       import_error: nil,
       imported: false,
       ready_count: 0,
       search_form: to_form(%{"query" => ""}, as: :search)
     )
     |> allow_upload(:client_excel,
       accept: ~w(.xlsx),
       max_entries: 1,
       max_file_size: ImportXlsx.max_bytes(),
       auto_upload: true
     )
     |> stream_configure(:clients, dom_id: &"client-#{&1.id}")
     |> load_clients()}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    {:noreply,
     socket
     |> assign(:search_form, to_form(%{"query" => query}, as: :search))
     |> load_clients()}
  end

  def handle_event("open-import", _, %{assigns: %{can_import: true}} = socket) do
    {:noreply, socket |> clear_import() |> assign(importing: true)}
  end

  def handle_event("close-import", _, socket),
    do: {:noreply, socket |> clear_import() |> assign(importing: false)}

  def handle_event("remove-import-file", %{"ref" => ref}, socket),
    do: {:noreply, socket |> cancel_upload(:client_excel, ref) |> assign(import_error: nil)}

  def handle_event("validate-import", _, socket),
    do:
      {:noreply,
       assign(socket, import_preview: nil, import_error: nil, imported: false, ready_count: 0)}

  def handle_event("preview-import", _, %{assigns: %{can_import: true}} = socket) do
    if Enum.any?(socket.assigns.uploads.client_excel.entries, &(!&1.done? || !&1.valid?)) do
      {:noreply,
       assign(socket, import_error: "Wait for the upload to finish, or remove the invalid file.")}
    else
      preview_import(socket)
    end
  end

  def handle_event(
        "save-import",
        _,
        %{assigns: %{can_import: true, imported: false, import_preview: %{rows: rows}}} = socket
      ) do
    case Import.save(socket.assigns.current_scope, rows) do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(
           imported: true,
           import_error: nil,
           import_preview: %{socket.assigns.import_preview | rows: results},
           ready_count: Enum.count(results, &(&1.status == :added))
         )
         |> load_clients()}

      {:error, reason} ->
        {:noreply, assign(socket, import_error: Import.error_message(reason))}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp preview_import(socket) do
    scope = socket.assigns.current_scope

    results =
      consume_uploaded_entries(socket, :client_excel, fn %{path: path}, _entry ->
        result = with {:ok, bytes} <- File.read(path), do: Import.preview(scope, bytes)
        {:ok, result}
      end)

    case results do
      [{:ok, preview}] ->
        {:noreply,
         assign(socket,
           import_preview: preview,
           import_error: nil,
           ready_count: Enum.count(preview.rows, &(&1.status == :ready))
         )}

      [{:error, reason}] ->
        {:noreply, assign(socket, import_error: Import.error_message(reason))}

      _ ->
        {:noreply, assign(socket, import_error: "Choose an Excel file first.")}
    end
  end

  defp clear_import(socket) do
    Enum.reduce(socket.assigns.uploads.client_excel.entries, socket, fn entry, acc ->
      cancel_upload(acc, :client_excel, entry.ref)
    end)
    |> assign(import_preview: nil, import_error: nil, imported: false, ready_count: 0)
  end

  defp cell(value) when is_binary(value), do: value
  defp cell(nil), do: "—"
  defp cell(_), do: "Formula or cell error"

  defp load_clients(socket) do
    query = socket.assigns.search_form[:query].value |> String.trim() |> String.downcase()
    clients = Clients.list_clients(socket.assigns.current_scope.current_org.id)

    matches =
      Enum.filter(clients, fn client ->
        String.contains?(String.downcase(client.name <> " " <> (client.gstin || "")), query)
      end)

    socket
    |> assign(:clients_empty?, clients == [])
    |> stream(:clients, matches, reset: true)
    |> assign(:client_count, length(matches))
  end

  @impl true
  def render(assigns) do
    rows = if assigns.import_preview, do: assigns.import_preview.rows, else: []

    assigns =
      assign(assigns,
        skipped_count: Enum.count(rows, &(&1.status in [:invalid, :skip])),
        invalid_rows?: Enum.any?(rows, &(&1.status == :invalid))
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="clients-page" class="pb-section space-y-block mx-auto w-full max-w-[960px]">
        <.page_header title="Clients">
          <:actions>
            <.button
              id="clients-import"
              phx-click="open-import"
              variant="soft"
              disabled={!@can_import}
              title={if !@can_import, do: "Your role cannot add clients."}
            >Import Excel</.button>
            <.button navigate={~p"/clients/new"} id="clients-add" variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> Add client
            </.button>
          </:actions>
        </.page_header>

        <.form
          for={@search_form}
          id="clients-search-form"
          phx-change="search"
          phx-submit="search"
          class="w-full max-w-sm"
        >
          <.input
            field={@search_form[:query]}
            id="clients-search"
            type="search"
            label="Find a client"
            shortcut="/"
            data-shortcut-search
            aria-keyshortcuts="/"
            placeholder="Search by name or GSTIN"
            phx-debounce="200"
          />
        </.form>

        <.card padding="none">
          <div class="px-4 py-3">
            <.data_table
              id="clients-table"
              rows={@streams.clients}
              row_navigate={fn client -> ~p"/clients/#{client.id}/edit" end}
              row_label={fn client -> "Edit #{client.name}" end}
              empty?={@client_count == 0}
              mode="worklist"
              surface="ghost"
              min_width="min-w-[640px]"
            >
              <:col :let={client} key="client" label="Client" row_header class="w-[50%]">
                <span class="font-medium">{client.name}</span>
              </:col>

              <:col :let={client} key="gstin" label="GSTIN">
                <span :if={client.gstin} class="whitespace-nowrap">{client.gstin}</span>
                <span :if={!client.gstin} class="text-ink-muted">—</span>
              </:col>

              <:col :let={_client} label="" class="w-10 whitespace-nowrap">
                <div class="flex justify-end">
                  <.icon name="hero-chevron-right-mini" class="text-ink-faint size-4" />
                </div>
              </:col>

              <:empty>
                <div id="clients-empty" class="space-y-block">
                  <p>
                    {if @clients_empty?, do: "No clients yet.", else: "No clients match your search."}
                  </p>

                  <.button :if={@clients_empty?} navigate={~p"/clients/new"} id="clients-add-first">
                    <.icon name="hero-plus" class="size-4" /> Add your first client
                  </.button>
                </div>
              </:empty>
            </.data_table>
          </div>
        </.card>
      </div>

      <.modal
        :if={@importing}
        id="clients-import-modal"
        title={
          if @imported,
            do: "#{@ready_count} #{if @ready_count == 1, do: "client", else: "clients"} added",
            else: "Import clients from Excel"
        }
        on_close="close-import"
        return_focus="#clients-import"
        width="wide"
      >
        <div class="space-y-block">
          <%= if @import_preview do %>
            <p
              :if={!@imported || @skipped_count > 0}
              id="clients-import-summary"
              class="text-ui"
              role="status"
            >
              <%= if !@imported do %>
                {@ready_count} {if @ready_count == 1, do: "client", else: "clients"} ready to add.
              <% end %>

              <span :if={@skipped_count > 0}>{@skipped_count} {if @skipped_count == 1,
                do: "row",
                else: "rows"} skipped.</span>
            </p>

            <p :if={!@imported} class="text-ink-muted text-ui">
              Worksheet: {@import_preview.sheet}. Existing clients will not be changed.
            </p>

            <p :if={@invalid_rows?} id="clients-import-corrections" class="text-ink-muted text-ui">
              Correct the flagged rows in Excel and upload again.
            </p>

            <div class="max-h-96 overflow-auto">
              <.data_table
                id="clients-import-preview"
                rows={@import_preview.rows}
                mode="review"
                min_width="min-w-[600px]"
              >
                <:col :let={row} label="Excel row">{row.row}</:col>

                <:col :let={row} label="Client name" row_header>{cell(row.name)}</:col>

                <:col :let={row} label="GSTIN">{cell(row.gstin)}</:col>

                <:col :let={row} label="GST username">{cell(row.gst_username)}</:col>

                <:col :let={row} label="Result">
                  <span class={[
                    "inline-flex items-center gap-2",
                    row.status == :invalid && "text-error"
                  ]}>
                    <.icon
                      :if={row.status == :added}
                      name="hero-check-circle-solid"
                      class="text-success size-4 shrink-0"
                    /> {row.message}
                  </span>
                </:col>
              </.data_table>
            </div>

            <.button
              :if={!@imported}
              id="clients-import-another"
              variant="ghost"
              phx-click="open-import"
            >Choose another file</.button>
          <% else %>
            <p class="text-ui">
              Use one worksheet with <strong>Client name</strong>, <strong>GSTIN</strong>
              and <strong>GST username</strong>
              headings in the first row. Leave GSTIN blank for an unregistered client.
              GST username can be left blank; when provided, it prefills the GST connection.
            </p>

            <.download_button
              id="clients-import-template"
              href={~p"/clients/import-template.xlsx"}
              variant="soft"
            >Download Excel template</.download_button>
            <.form
              for={%{}}
              id="clients-import-form"
              phx-change="validate-import"
              phx-submit="preview-import"
              class="space-y-block"
            >
              <.file_drop
                id="clients-import-upload"
                upload={@uploads.client_excel}
                prompt="Choose Excel file"
                hint="Up to 1,000 clients · .xlsx · 2 MB"
                on_cancel="remove-import-file"
              />
            </.form>
          <% end %>

          <p :if={@import_error} id="clients-import-error" role="alert" class="text-error text-ui">
            {@import_error}
          </p>
        </div>

        <:footer>
          <.button :if={@imported} id="clients-import-another" variant="ghost" phx-click="open-import">Import another file</.button>
          <.button
            id="clients-import-close"
            phx-click="close-import"
            variant={if @imported, do: "primary", else: "ghost"}
          >{if @imported,
            do: "Done",
            else: "Cancel"}</.button>
          <%= if @import_preview do %>
            <.button
              :if={!@imported}
              id="clients-import-save"
              phx-click="save-import"
              disabled={@ready_count == 0}
              phx-disable-with="Adding…"
            >Add {@ready_count} {if @ready_count == 1, do: "client", else: "clients"}</.button>
          <% else %>
            <.button
              id="clients-import-preview-button"
              type="submit"
              form="clients-import-form"
              disabled={
                @uploads.client_excel.entries == [] ||
                  Enum.any?(@uploads.client_excel.entries, &(!&1.done? || !&1.valid?))
              }
              phx-disable-with="Reading…"
            >Preview clients</.button>
          <% end %>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end
end
