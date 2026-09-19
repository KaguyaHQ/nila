defmodule NilaWeb.NoticesLive do
  use NilaWeb, :live_view
  alias Nila.{Clients, Notices}
  alias Nila.Accounts.Policy

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: "Notices",
       clients: Clients.list_clients(scope.current_org.id),
       selected: nil,
       notice: nil,
       checks_open: false,
       polling: false,
       error: nil,
       can_connect: Policy.can?(scope, :manage_connectors),
       can_check: Policy.can?(scope, :edit_records)
     )
     |> stream(:notices, [])
     |> stream(:client_checks, [])}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, notice} <- Notices.fetch(org_id(socket), id) do
      documents = Notices.documents(notice)
      default_index = Enum.find_index(documents, &(&1["ct"] == "application/pdf")) || 0

      index =
        case Integer.parse(params["document"] || "") do
          {index, ""} when index >= 0 and index < length(documents) -> index
          _ -> default_index
        end

      {:noreply,
       assign(socket,
         page_title: "#{type_label(notice.notice_type)} · #{notice.client.name}",
         notice: notice,
         selected: notice.client,
         documents: documents,
         document_index: index,
         document: Enum.at(documents, index),
         document_form: to_form(%{"index" => to_string(index)}, as: :document)
       )}
    else
      _ ->
        {:noreply,
         socket |> put_flash(:error, "Notice not found.") |> push_navigate(to: ~p"/notices")}
    end
  end

  def handle_params(params, _uri, socket) do
    selected = Enum.find(socket.assigns.clients, &(to_string(&1.id) == params["client_id"]))

    {:noreply,
     socket
     |> assign(
       page_title: "Notices",
       selected: selected,
       notice: nil,
       error: nil
     )
     |> load()}
  end

  @impl true
  def handle_event("select_document", %{"document" => %{"index" => index}}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/notices/#{socket.assigns.notice.id}?#{%{document: index}}")}
  end

  def handle_event("select_client", %{"filter" => %{"client_id" => id}}, socket) do
    {:noreply, push_patch(socket, to: ~p"/notices?#{%{client_id: id}}")}
  end

  def handle_event("toggle_client_checks", _, socket) do
    {:noreply, assign(socket, checks_open: not socket.assigns.checks_open)}
  end

  def handle_event("connect", %{"client_id" => id}, %{assigns: %{can_connect: true}} = socket) do
    case Enum.find(socket.assigns.clients, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      client ->
        open_connection(client.id)
        {:noreply, assign(socket, error: nil)}
    end
  end

  def handle_event("check", %{"client_id" => id}, %{assigns: %{can_check: true}} = socket) do
    case Enum.find(socket.assigns.clients, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      client ->
        case Notices.enqueue(socket.assigns.current_scope, client.id) do
          {:ok, _} ->
            {:noreply, socket |> assign(error: nil) |> load()}

          {:error, reason} when reason in [:not_found, :session_expired] ->
            if socket.assigns.can_connect, do: open_connection(client.id)

            {:noreply,
             socket
             |> assign(
               error: if(socket.assigns.can_connect, do: nil, else: Notices.error_message(reason))
             )
             |> load()}

          {:error, reason} ->
            {:noreply, socket |> assign(error: Notices.error_message(reason)) |> load()}
        end
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp open_connection(client_id) do
    send_update(NilaWeb.Gst.ConnectionComponent,
      id: "gst-connection",
      request: %{
        client_id: client_id,
        continuation: :check_notices,
        return_focus: "#client-check-action-#{client_id}"
      }
    )
  end

  @impl true
  def handle_info({:gst_connected, client_id, :check_notices}, socket) do
    case Notices.enqueue(socket.assigns.current_scope, client_id) do
      {:ok, _} ->
        {:noreply, socket |> assign(error: nil) |> load()}

      {:error, reason} ->
        {:noreply, socket |> assign(error: Notices.error_message(reason)) |> load()}
    end
  end

  def handle_info(:refresh_notices, socket),
    do: {:noreply, socket |> assign(polling: false) |> load()}

  defp load(socket) do
    selected = socket.assigns.selected
    checks = Notices.client_checks(org_id(socket))
    notices = Notices.list(org_id(socket))
    notices = if selected, do: Enum.filter(notices, &(&1.client_id == selected.id)), else: notices
    checking = Enum.any?(checks, &(&1.state == :checking))
    attention_count = Enum.count(checks, &(&1.state not in [:checked, :checking]))

    socket =
      socket
      |> assign(
        checks: checks,
        clients: Enum.map(checks, & &1.client),
        attention_count: attention_count,
        client_count: length(checks),
        count: length(notices)
      )
      |> assign(
        :filter_form,
        to_form(%{"client_id" => if(selected, do: to_string(selected.id), else: "")}, as: :filter)
      )
      |> stream(:notices, notices, reset: true)
      |> stream(:client_checks, checks, reset: true)

    if checking and connected?(socket) and not socket.assigns.polling do
      Process.send_after(self(), :refresh_notices, 1500)
      assign(socket, polling: true)
    else
      socket
    end
  end

  defp org_id(socket), do: socket.assigns.current_scope.current_org.id
  defp date(nil), do: "Not supplied"
  defp date(date), do: Calendar.strftime(date, "%d %b %Y")
  defp checked_at(nil), do: "Never checked"

  defp checked_at(time),
    do: Calendar.strftime(DateTime.add(time, 19_800), "%d %b %Y at %H:%M IST")

  defp check_label(:missing_gstin), do: "GSTIN missing"
  defp check_label(:not_connected), do: "Not connected"
  defp check_label(:expired), do: "Login expired"
  defp check_label(:failed), do: "Check failed"
  defp check_label(:not_checked), do: "Not checked yet"
  defp check_label(:checking), do: "Checking…"
  defp check_label(:checked), do: "Checked successfully"

  defp check_summary(0, 0), do: "No clients yet."
  defp check_summary(0, _total), do: "View clients and last successful check times."
  defp check_summary(1, _total), do: "1 client needs attention before their next check."

  defp check_summary(count, _total),
    do: "#{count} clients need attention before their next check."

  defp type_label("REMINDER"), do: "Reminder"
  defp type_label(type), do: type || "Notice"

  defp period(%{"fromMonth" => fm, "fromYear" => fy, "toMonth" => tm, "toYear" => ty}),
    do: "#{fm} #{fy} – #{tm} #{ty}"

  defp period(_), do: "Not supplied"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
      active_client={if @notice, do: @notice.client}
    >
      <div id="notices-page" class="pb-section space-y-block mx-auto w-full max-w-[1400px]">
        <%= if @notice do %>
          <.text_link navigate={~p"/notices?#{%{client_id: @notice.client_id}}"} id="notices-back">
            <.icon name="hero-arrow-left" class="size-4" /> Notices
          </.text_link>
          <.page_header title={"#{type_label(@notice.notice_type)} · #{@notice.client.name}"} />
          <dl id="notice-details" class="text-ui flex flex-wrap gap-x-8 gap-y-3">
            <div>
              <dt class="text-ink-muted">Reference</dt>

              <dd class="font-medium">{@notice.reference}</dd>
            </div>

            <div>
              <dt class="text-ink-muted">GSTIN</dt>

              <dd>{@notice.gstin}</dd>
            </div>

            <div>
              <dt class="text-ink-muted">Issued</dt>

              <dd>{date(@notice.issued_on)}</dd>
            </div>

            <div>
              <dt class="text-ink-muted">Reply date in notice</dt>

              <dd>{date(@notice.reply_due_on)}</dd>
            </div>

            <div :if={period(@notice.payload["detail"]["taxPeriod"]) != "Not supplied"}>
              <dt class="text-ink-muted">Tax period</dt>

              <dd>{period(@notice.payload["detail"]["taxPeriod"])}</dd>
            </div>
          </dl>

          <div :if={@document} id="notice-documents" class="space-y-3">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <.form
                :if={length(@documents) > 1}
                for={@document_form}
                id="notice-document-form"
                phx-change="select_document"
                class="max-w-md min-w-0 flex-1"
              >
                <.input
                  field={@document_form[:index]}
                  type="select"
                  label="Document"
                  options={
                    Enum.with_index(@documents)
                    |> Enum.map(fn {doc, index} -> {"#{index + 1}. #{doc["docName"]}", index} end)
                  }
                />
              </.form>

              <p :if={length(@documents) == 1} class="text-ui font-medium">Original notice</p>

              <.text_link
                :if={@document["ct"] == "application/pdf"}
                href={~p"/notices/#{@notice.id}/documents/#{@document_index}"}
                target="_blank"
                rel="noopener"
                id={"notice-document-#{@document_index}"}
              >
                Open original <.icon name="hero-arrow-top-right-on-square" class="size-4" />
              </.text_link>
            </div>

            <section
              :if={@document["ct"] == "application/pdf"}
              id="notice-reader"
              class="border-rule h-[calc(100dvh-19rem)] min-h-[480px] overflow-hidden rounded-lg border"
              aria-label="Original notice PDF"
            >
              <NilaWeb.Components.PdfViewer.viewer
                id={"notice-pdf-#{@notice.id}-#{@document_index}"}
                url={~p"/notices/#{@notice.id}/documents/#{@document_index}"}
                pages={[]}
                document_label="Notice"
              />
            </section>

            <p :if={@document["ct"] != "application/pdf"} class="text-ink-muted text-ui">
              Preview unavailable for this file type. View this attachment on the GST portal.
            </p>
          </div>

          <p :if={!@document} id="notice-documents-empty" class="text-ink-muted text-ui">
            No documents are available for this notice.
          </p>

          <p class="text-ink-muted text-ui">
            Reply and closure status are not supplied. Check the GST portal for the latest case status.
          </p>
        <% else %>
          <.page_header title="Notices" />
          <p id="notices-coverage" class="text-ink-muted text-ui">
            Fetches adjudication and enforcement notices from GST. Check the GST portal for other notices and a complete record.
          </p>

          <div class="gap-block flex flex-wrap items-end justify-between">
            <.form
              for={@filter_form}
              id="notices-filter"
              phx-change="select_client"
              phx-submit="select_client"
              class="w-full max-w-sm"
            >
              <.input
                field={@filter_form[:client_id]}
                id="notices-client"
                type="select"
                label="Client"
                options={[{"All clients", ""} | Enum.map(@clients, &{&1.name, &1.id})]}
              />
            </.form>
          </div>

          <.fold id="client-checks" open={@checks_open} on_toggle="toggle_client_checks">
            <:summary>
              <.fold_summary title="Client checks · Entire firm">
                <:detail>
                  <span id="client-checks-summary">{check_summary(@attention_count, @client_count)}</span>
                </:detail>
              </.fold_summary>
            </:summary>

            <div class="pt-block space-y-block">
              <p class="text-ink-muted text-ui">
                Checks cover the past 60 days. Saved notices are retained.
              </p>

              <p :if={!@can_connect} id="client-check-permissions" class="text-ink-muted text-ui">
                {if @can_check,
                  do: "Ask the workspace owner to connect or reconnect GST accounts.",
                  else:
                    "Your role can view notices. An operator or owner must run checks; an owner must connect GST accounts."}
              </p>

              <.data_table
                id="client-checks-table"
                rows={@streams.client_checks}
                mode="worklist"
                empty?={@client_count == 0}
              >
                <:col :let={row} label="Client" row_header>
                  <.text_link
                    patch={~p"/notices?#{%{client_id: row.id}}"}
                    id={"client-check-filter-#{row.id}"}
                    class="font-medium"
                  >{row.client.name}</.text_link>
                </:col>

                <:col :let={row} label="Check status">
                  <span
                    id={"client-check-status-#{row.id}"}
                    class={[row.state == :failed && "text-error"]}
                  >{check_label(row.state)}</span>
                  <p :if={row.state == :failed} class="text-ink-muted text-ui">
                    {row.last_error}
                  </p>
                </:col>

                <:col :let={row} label="Last successful check" class="whitespace-nowrap">
                  <span id={"client-check-time-#{row.id}"}>{checked_at(row.last_checked_at)}</span>
                </:col>

                <:col :let={row} label="Action" align="right">
                  <%= cond do %>
                    <% row.state == :missing_gstin -> %>
                      <.button
                        :if={@can_check}
                        navigate={~p"/clients/#{row.id}/edit"}
                        variant="soft"
                        id={"client-check-action-#{row.id}"}
                      >Add GSTIN</.button>
                      <.button
                        :if={!@can_check}
                        disabled
                        variant="soft"
                        title="Ask an operator or owner to add the GSTIN."
                      >Add GSTIN</.button>
                    <% row.state in [:not_connected, :expired] -> %>
                      <.button
                        id={"client-check-action-#{row.id}"}
                        phx-click="connect"
                        phx-value-client_id={row.id}
                        variant="soft"
                        disabled={!@can_connect}
                        aria-describedby={if !@can_connect, do: "client-check-permissions"}
                      >
                        {if row.state == :expired, do: "Reconnect GST", else: "Connect GST"}
                      </.button>
                    <% true -> %>
                      <.button
                        id={"client-check-action-#{row.id}"}
                        phx-click="check"
                        phx-value-client_id={row.id}
                        variant="soft"
                        disabled={!@can_check || row.state == :checking}
                        aria-describedby={if !@can_check, do: "client-check-permissions"}
                      >
                        {case row.state do
                          :checking -> "Checking…"
                          :failed -> "Try again"
                          _ -> "Check notices"
                        end}
                      </.button>
                  <% end %>
                </:col>

                <:empty>
                  <.text_link navigate={~p"/clients/new"}>Add a client to check GST notices.</.text_link>
                </:empty>
              </.data_table>
            </div>
          </.fold>

          <p :if={@error} id="notices-error" role="alert" class="text-error text-ui">
            {@error}
          </p>

          <.data_table
            id="notices-table"
            rows={@streams.notices}
            mode="worklist"
            empty?={@count == 0}
            row_navigate={fn n -> ~p"/notices/#{n.id}" end}
            row_label={fn n -> "Open notice #{n.reference}" end}
          >
            <:col :let={n} label="Notice" row_header>
              <span class="font-medium">{type_label(n.notice_type)}</span><div class="text-ink-muted">
                {n.reference}
              </div>
            </:col>

            <:col :let={n} label="Client">{n.client.name}</:col>

            <:col :let={n} label="Issued" class="whitespace-nowrap">{date(n.issued_on)}</:col>

            <:col :let={n} label="Reply date in notice" class="whitespace-nowrap">
              {date(n.reply_due_on)}
            </:col>

            <:empty>
              <p id="notices-empty">
                No saved notices{if @selected, do: " for this client", else: ""}. This does not confirm that there are no notices on the GST portal.
              </p>
            </:empty>
          </.data_table>
        <% end %>
      </div>

      <.live_component
        module={NilaWeb.Gst.ConnectionComponent}
        id="gst-connection"
        current_scope={@current_scope}
      />
    </Layouts.app>
    """
  end
end
