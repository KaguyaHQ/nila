defmodule NilaWeb.Gst.Gstr2bLive do
  use NilaWeb, :live_view
  alias Nila.Accounts.Policy
  alias Nila.Gst.Portal
  alias Nila.Gst.Portal.Gstr2b
  alias Nila.Gst.Purchase.PortalImport
  alias Nila.Gst.Intake.Dumps

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope
    clients = Nila.Clients.list_clients(scope.current_org.id)
    if connected?(socket), do: Gstr2b.subscribe(scope.current_org.id)

    client_id =
      params["client_id"] || (scope.current_client && to_string(scope.current_client.id)) || ""

    period =
      params["period"] ||
        Date.utc_today()
        |> Date.beginning_of_month()
        |> Date.add(-1)
        |> Date.to_iso8601()
        |> String.slice(0, 7)

    {:ok,
     socket
     |> assign(
       page_title: "GSTR-2B",
       clients: clients,
       can_fetch: Policy.can?(scope, :edit_records),
       can_connect: Policy.can?(scope, :manage_connectors),
       can_export: Policy.can?(scope, :export),
       requested_fetch: nil,
       polling: false,
       error: nil
     )
     |> select(client_id, period)}
  end

  defp select(socket, client_id, period) do
    client = Enum.find(socket.assigns.clients, &(to_string(&1.id) == client_id))

    socket
    |> assign(
      client: client,
      period: period,
      form: to_form(%{"client_id" => client_id, "period" => period}, as: :statement)
    )
    |> reload()
  end

  defp reload(socket) do
    client = socket.assigns.client
    org_id = socket.assigns.current_scope.current_org.id
    statement = if client, do: Gstr2b.saved(org_id, client.id, socket.assigns.period)

    connection_state =
      cond do
        is_nil(client) ->
          :no_client

        not Nila.Gstin.valid?(client.gstin) ->
          :missing_gstin

        true ->
          case Portal.connection(org_id, client.id) do
            {:ok, connection} ->
              if Portal.session_expired?(connection, DateTime.utc_now()),
                do: :expired,
                else: :connected

            _ ->
              :not_connected
          end
      end

    fetching = Gstr2b.fetching?(statement)

    if fetching and connected?(socket) and not socket.assigns.polling,
      do: Process.send_after(self(), :refresh_statement, 1000)

    assign(socket,
      statement: statement,
      gst_connected: connection_state == :connected,
      connection_state: connection_state,
      fetching: fetching,
      polling: fetching or socket.assigns.polling
    )
  end

  @impl true
  def handle_event("reconnect", _, %{assigns: %{can_connect: true, client: client}} = socket)
      when not is_nil(client) do
    send_update(NilaWeb.Gst.ConnectionComponent,
      id: "gst-connection",
      request: %{
        client_id: client.id,
        continuation: {:fetch_2b, socket.assigns.period},
        return_focus: "#gstr2b-reconnect"
      }
    )

    {:noreply, request_fetch(socket)}
  end

  def handle_event("reconnect", _, socket), do: {:noreply, socket}

  def handle_event("select", %{"statement" => %{"client_id" => id, "period" => period}}, socket) do
    {:noreply, socket |> assign(error: nil, requested_fetch: nil) |> select(id, period)}
  end

  def handle_event("fetch", %{"statement" => %{"client_id" => id, "period" => period}}, socket) do
    socket = socket |> select(id, period) |> request_fetch()

    result =
      if socket.assigns.client,
        do: Gstr2b.enqueue(socket.assigns.current_scope, socket.assigns.client.id, period),
        else: {:error, :choose_client}

    case result do
      {:ok, _} ->
        {:noreply, socket |> mark_enqueued() |> assign(error: nil) |> reload()}

      {:error, :choose_client} ->
        {:noreply, assign(socket, error: "Choose a client.", requested_fetch: nil)}

      {:error, reason} when reason in [:not_found, :session_expired] ->
        if socket.assigns.can_connect && Nila.Gstin.valid?(socket.assigns.client.gstin) do
          send_update(NilaWeb.Gst.ConnectionComponent,
            id: "gst-connection",
            request: %{
              client_id: socket.assigns.client.id,
              continuation: {:fetch_2b, period},
              return_focus: "#gstr2b-fetch"
            }
          )

          {:noreply, socket |> assign(error: nil) |> reload()}
        else
          {:noreply,
           assign(socket,
             error: "Ask the workspace owner to connect this client's GST account.",
             requested_fetch: nil
           )}
        end

      {:error, reason} ->
        {:noreply,
         socket |> assign(error: Gstr2b.error_message(reason), requested_fetch: nil) |> reload()}
    end
  end

  def handle_event("review", _, socket), do: {:noreply, review_purchases(socket)}

  @impl true
  def handle_info({:gst_connected, client_id, {:fetch_2b, period}}, socket) do
    if socket.assigns.requested_fetch &&
         socket.assigns.requested_fetch.client_id == client_id &&
         socket.assigns.requested_fetch.period == period do
      case Gstr2b.enqueue(socket.assigns.current_scope, client_id, period) do
        {:ok, _} ->
          {:noreply, socket |> mark_enqueued() |> assign(error: nil) |> reload()}

        {:error, reason} ->
          {:noreply,
           socket |> assign(error: Gstr2b.error_message(reason), requested_fetch: nil) |> reload()}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:gst_statement_fetched, _id}, socket),
    do: {:noreply, socket |> reload() |> complete_fetch()}

  def handle_info(:refresh_statement, socket),
    do: {:noreply, socket |> assign(polling: false) |> reload() |> complete_fetch()}

  def handle_info(_, socket), do: {:noreply, socket}

  defp request_fetch(socket) do
    client = socket.assigns.client
    statement = socket.assigns.statement

    assign(socket,
      requested_fetch:
        if(client,
          do: %{
            client_id: client.id,
            period: socket.assigns.period,
            phase: :awaiting_enqueue,
            fetched_at: statement && statement.fetched_at
          }
        )
    )
  end

  defp mark_enqueued(socket),
    do: assign(socket, requested_fetch: %{socket.assigns.requested_fetch | phase: :enqueued})

  defp complete_fetch(%{assigns: %{requested_fetch: nil}} = socket), do: socket

  defp complete_fetch(%{assigns: %{requested_fetch: %{phase: :awaiting_enqueue}}} = socket),
    do: socket

  defp complete_fetch(socket) do
    request = socket.assigns.requested_fetch
    statement = socket.assigns.statement

    cond do
      is_nil(statement) ->
        socket

      statement.client_id != request.client_id || statement.period != request.period ->
        socket

      statement.status == "failed" ->
        assign(socket, requested_fetch: nil)

      statement.status == "ready" && statement.fetched_at != request.fetched_at ->
        socket |> assign(requested_fetch: nil) |> review_purchases(:fresh)

      true ->
        socket
    end
  end

  defp review_purchases(socket, mode \\ :saved) do
    client = socket.assigns.client
    period = socket.assigns.period

    if client && match?({:ok, _}, Gstr2b.month(period)) do
      current =
        if mode == :saved do
          PortalImport.current_dump(
            socket.assigns.statement,
            Dumps.list(socket.assigns.current_scope.current_org.id, client.id, period)
          )
        end

      result =
        if socket.assigns.can_fetch && !(current && current.status != "failed"),
          do: PortalImport.import(socket.assigns.current_scope, client.id, period),
          else: {:ok, :read_only}

      case result do
        {:ok, _} ->
          push_navigate(socket, to: ~p"/gst/#{client.id}/#{period}/purchases")

        {:error, reason} when is_binary(reason) ->
          assign(socket, error: reason)

        {:error, _} ->
          assign(socket,
            error: "Could not prepare this statement for purchase review. Try again."
          )
      end
    else
      assign(socket, error: "Choose a client and a valid return month.")
    end
  end

  defp fetched_at(time),
    do: time |> DateTime.add(19_800) |> Calendar.strftime("%d %b %Y at %H:%M IST")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div id="gstr2b-page" class="space-y-block mx-auto w-full max-w-[960px]">
        <.page_header title="GSTR-2B">
          Fetch the portal statement to compare with this client's purchase records.
        </.page_header>

        <.card :if={@statement && @statement.fetched_at} id="gstr2b-saved">
          <div class="space-y-block">
            <p class="font-medium">{@client.name} · {@statement.period}</p>

            <p id="gstr2b-fetched-at" class="text-ink-muted text-ui">
              GSTR-2B fetched {fetched_at(@statement.fetched_at)}
            </p>

            <p class="text-ui">
              Continue to purchases to compare this statement with the client's books.
            </p>

            <div class="gap-related flex flex-wrap items-center">
              <.button
                id="gstr2b-review-purchases"
                variant="primary"
                phx-click="review"
                disabled={@fetching}
              >
                Review purchases
              </.button>

              <.download_button
                :if={@can_export}
                id="gstr2b-download"
                href={~p"/gst/2b/statements/#{@statement.id}/download"}
                variant="ghost"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" /> Download JSON
              </.download_button>
            </div>
          </div>
        </.card>

        <.card>
          <.form
            for={@form}
            id="gstr2b-form"
            phx-change="select"
            phx-submit="fetch"
            class="space-y-block"
          >
            <.input
              field={@form[:client_id]}
              id="gstr2b-client"
              type="select"
              label="Client"
              prompt="Choose a client"
              options={Enum.map(@clients, &{&1.name, &1.id})}
            />
            <.input
              field={@form[:period]}
              id="gstr2b-period"
              type="month"
              label="Return month"
              required
            />
            <p :if={@client && !@gst_connected} id="gstr2b-connection" class="text-ui">
              {case @connection_state do
                :expired -> "Your GST session expired. Fetch GSTR-2B to reconnect and continue."
                :missing_gstin -> "Add a valid GSTIN to this client before fetching."
                _ -> "Fetch GSTR-2B to connect this client's GST account using an OTP."
              end}
            </p>

            <.text_link
              :if={@connection_state == :missing_gstin && @can_fetch}
              navigate={~p"/clients/#{@client.id}/edit"}
            >Edit client GSTIN</.text_link>
            <p
              :if={@client && !@gst_connected && !@can_connect && @can_fetch}
              id="gstr2b-connect-permission"
              class="text-ink-muted text-ui"
            >
              Ask the workspace owner to connect or reconnect this client's GST account.
            </p>

            <p :if={!@can_fetch} id="gstr2b-permission" class="text-ink-muted text-ui">
              Your role can review saved records. Ask an operator to fetch a new statement.
            </p>

            <.button
              id="gstr2b-fetch"
              type="submit"
              variant={if @statement && @statement.fetched_at, do: "soft", else: "primary"}
              disabled={
                !@can_fetch || !@client || @connection_state == :missing_gstin ||
                  (!@gst_connected && !@can_connect) || @fetching
              }
              phx-disable-with="Requesting…"
            >
              {if @fetching,
                do: "Fetching GSTR-2B…",
                else:
                  if(@statement && @statement.fetched_at,
                    do: "Refresh GSTR-2B",
                    else: "Fetch and reconcile"
                  )}
            </.button>
          </.form>
        </.card>

        <p :if={@error} id="gstr2b-error" role="alert" class="text-error text-ui">{@error}</p>

        <p
          :if={@statement && @statement.last_error}
          id="gstr2b-fetch-error"
          role="alert"
          class="text-error text-ui"
        >
          {@statement.last_error}
        </p>

        <.button
          :if={@can_connect && @statement && @statement.last_error}
          id="gstr2b-reconnect"
          phx-click="reconnect"
          variant="ghost"
        >Reconnect GST and fetch</.button>
        <p
          :if={@client && !(@statement && @statement.fetched_at)}
          id="gstr2b-empty"
          class="text-ink-muted text-ui"
        >
          No statement saved for this month.
        </p>
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
