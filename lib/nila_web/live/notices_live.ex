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
       connecting_client: nil,
       connection_return_focus: nil,
       checks_open: false,
       connecting: false,
       challenge: nil,
       busy: false,
       polling: false,
       error: nil,
       can_connect: Policy.can?(scope, :manage_connectors),
       can_check: Policy.can?(scope, :edit_records)
     )
     |> assign(:connection_form, to_form(%{"username" => ""}, as: :connection))
     |> assign(:otp_form, to_form(%{}, as: :verification))
     |> stream(:notices, [])
     |> stream(:client_checks, [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, notice} <- Notices.fetch(org_id(socket), id) do
      {:noreply,
       assign(socket,
         notice: notice,
         selected: notice.client,
         documents: Notices.documents(notice)
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
       selected: selected,
       notice: nil,
       connecting: false,
       connecting_client: nil,
       challenge: nil,
       error: nil
     )
     |> load()}
  end

  @impl true
  def handle_event("select_client", %{"filter" => %{"client_id" => id}}, socket) do
    {:noreply, push_patch(socket, to: ~p"/notices?#{%{client_id: id}}")}
  end

  def handle_event("toggle_client_checks", _, socket) do
    {:noreply, assign(socket, checks_open: not socket.assigns.checks_open)}
  end

  def handle_event(
        "connect",
        %{"client_id" => id},
        %{assigns: %{can_connect: true, busy: false}} = socket
      ) do
    case Enum.find(socket.assigns.checks, &(to_string(&1.id) == id)) do
      %{client: %{gstin: gstin} = client, connection: connection} when is_binary(gstin) ->
        username = if connection, do: connection.username, else: ""

        {:noreply,
         socket
         |> assign(
           connecting: true,
           connecting_client: client,
           error: nil,
           challenge: nil,
           connection_return_focus: "#client-check-action-#{client.id}"
         )
         |> assign(:connection_form, to_form(%{"username" => username}, as: :connection))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_connection", _, %{assigns: %{busy: false}} = socket),
    do:
      {:noreply,
       assign(socket, connecting: false, connecting_client: nil, challenge: nil, error: nil)}

  def handle_event(
        "request_otp",
        %{"connection" => %{"username" => username}},
        %{assigns: %{busy: false, connecting_client: selected, can_connect: true}} = socket
      )
      when not is_nil(selected) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(busy: true, error: nil)
     |> start_async(:request_otp, fn -> Nila.Gst.Portal.request_otp(scope, selected.id, username) end)}
  end

  def handle_event(
        "verify_otp",
        %{"verification" => %{"otp" => otp}},
        %{assigns: %{busy: false, challenge: challenge, can_connect: true}} = socket
      )
      when not is_nil(challenge) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(busy: true, error: nil)
     |> start_async(:verify_otp, fn -> Nila.Gst.Portal.verify_otp(scope, challenge, otp) end)}
  end

  def handle_event("check", %{"client_id" => id}, %{assigns: %{can_check: true}} = socket) do
    case Enum.find(socket.assigns.clients, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      client ->
        case Notices.enqueue(socket.assigns.current_scope, client.id) do
          {:ok, _} ->
            {:noreply, socket |> assign(error: nil) |> load()}

          {:error, reason} ->
            {:noreply, socket |> assign(error: Notices.error_message(reason)) |> load()}
        end
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:request_otp, {:ok, {:ok, challenge}}, socket),
    do: {:noreply, assign(socket, busy: false, challenge: challenge)}

  def handle_async(:verify_otp, {:ok, {:ok, _}}, socket),
    do:
      {:noreply,
       socket
       |> assign(busy: false, connecting: false, connecting_client: nil, challenge: nil)
       |> put_flash(:info, "GST account connected.")
       |> load()}

  def handle_async(_, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, busy: false, error: Notices.error_message(reason))}

  def handle_async(_, {:exit, _}, socket),
    do: {:noreply, assign(socket, busy: false, error: Notices.error_message(:unavailable))}

  @impl true
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
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div id="notices-page" class="pb-section space-y-block mx-auto w-full max-w-[1400px]">
        <%= if @notice do %>
          <.page_header title={type_label(@notice.notice_type)}>
            <:actions>
              <.button
                navigate={~p"/notices?#{%{client_id: @notice.client_id}}"}
                variant="soft"
                id="notices-back"
              >All notices</.button>
            </:actions>
          </.page_header>
          
          <p class="text-ui">{@notice.client.name} · {@notice.gstin}</p>
          
          <.card>
            <dl id="notice-details" class="gap-block grid grid-cols-1 md:grid-cols-2">
              <div>
                <dt class="text-ink-muted text-ui">Reference number</dt><dd class="text-ui font-medium">
                  {@notice.reference}
                </dd>
              </div>
              
              <div>
                <dt class="text-ink-muted text-ui">Issued</dt><dd class="text-ui">
                  {date(@notice.issued_on)}
                </dd>
              </div>
              
              <div>
                <dt class="text-ink-muted text-ui">Reply date in notice</dt><dd class="text-ui">
                  {date(@notice.reply_due_on)}
                </dd>
              </div>
              
              <div>
                <dt class="text-ink-muted text-ui">Tax period</dt><dd class="text-ui">
                  {period(@notice.payload["detail"]["taxPeriod"])}
                </dd>
              </div>
            </dl>
          </.card>
          
          <p class="text-ink-muted text-ui">
            Check the GST portal to see whether a reply was filed or the matter is closed.
          </p>
          
          <.data_table
            id="notice-documents"
            rows={Enum.with_index(@documents)}
            mode="worklist"
            empty?={@documents == []}
          >
            <:col :let={{doc, _}} label="Document" row_header>{doc["docName"]}</:col>
            
            <:col :let={{doc, index}} label="" align="right">
              <.button
                :if={doc["ct"] == "application/pdf"}
                href={~p"/notices/#{@notice.id}/documents/#{index}"}
                target="_blank"
                rel="noopener"
                variant="soft"
                id={"notice-document-#{index}"}
              >View PDF</.button>
              <span :if={doc["ct"] != "application/pdf"} class="text-ink-muted">Preview unavailable for this file type</span>
            </:col>
            
            <:empty>No documents are available for this notice.</:empty>
          </.data_table>
        <% else %>
          <.page_header title="Notices" />
          <p id="notices-coverage" class="text-ink-muted text-ui">
            Some notices and orders may be missing. Check the GST portal for a complete record.
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
          
          <p :if={@error && !@connecting} id="notices-error" role="alert" class="text-error text-ui">
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
      
      <.modal
        :if={@connecting}
        id="notice-connection-modal"
        title={"Connect GST · #{@connecting_client.name}"}
        on_close="close_connection"
        close_on_escape={!@busy}
        return_focus={@connection_return_focus}
      >
        <p :if={@error} id="notice-connection-error" role="alert" class="text-error text-ui">
          {@error}
        </p>
        
        <%= if @challenge do %>
          <p class="mb-block text-ui">
            Enter the OTP sent to this client's GST-registered phone or email.
          </p>
          
          <.form for={@otp_form} id="notice-otp-form" phx-submit="verify_otp">
            <.input
              field={@otp_form[:otp]}
              id="notice-otp"
              label="OTP"
              required
              pattern="[0-9]{6}"
              minlength="6"
              maxlength="6"
              inputmode="numeric"
              autocomplete="one-time-code"
              disabled={@busy}
            />
          </.form>
        <% else %>
          <.form for={@connection_form} id="notice-connect-form" phx-submit="request_otp">
            <.input
              field={@connection_form[:username]}
              id="notice-gst-username"
              label="GST portal username"
              required
              maxlength="100"
              disabled={@busy}
            />
          </.form>
        <% end %>
        
        <:footer>
          <.button phx-click="close_connection" variant="ghost" disabled={@busy}>Cancel</.button>
          <.button
            type="submit"
            form={if @challenge, do: "notice-otp-form", else: "notice-connect-form"}
            disabled={@busy}
            id="notice-connect-submit"
          >
            {cond do
              @busy -> "Please wait…"
              @challenge -> "Verify OTP"
              true -> "Send OTP"
            end}
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end
end
