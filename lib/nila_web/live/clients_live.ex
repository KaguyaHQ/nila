defmodule NilaWeb.ClientsLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Gst.Purchase.{Months, Register}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Clients")
     |> assign(:clients, list_clients(socket))}
  end

  defp list_clients(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    latest = Months.latest_by_client(org_id)

    org_id
    |> Clients.list_clients()
    |> Enum.map(&client_view(&1, latest[&1.id]))
  end

  defp list_clients(_socket), do: []

  defp client_view(client, month) do
    %{
      id: client.id,
      name: client.name,
      type: type_label(client.type),
      gstin: client.gstin,
      month: month && %{period: month.period, state: month.state},
      need_decision: month && Register.need_decision(month.summary)
    }
  end

  defp type_label(type), do: type |> to_string() |> String.capitalize()

  defp state_variant("reviewed"), do: "success"
  defp state_variant("filed"), do: "success"
  defp state_variant("worked"), do: "warning"
  defp state_variant(_state), do: "neutral"

  # Click follows the work: latest month when one exists, else start one —
  # intake pre-scoped to this client.
  defp row_path(%{month: %{period: period}, id: id}), do: ~p"/gst/#{id}/#{period}"
  defp row_path(%{id: id}), do: ~p"/gst/upload?client_id=#{id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="clients-page" class="space-y-section mx-auto max-w-5xl">
        <.page_header eyebrow="Clients" title="Clients">
          Every business the firm files for, with where their GST work stands.
          <:actions>
            <.button navigate={~p"/clients/new"} id="clients-add">Add client</.button>
          </:actions>
        </.page_header>

        <.data_table
          id="clients-table"
          rows={@clients}
          row_id={fn client -> "client-#{client.id}" end}
          row_click={fn client -> JS.navigate(row_path(client)) end}
          empty?={@clients == []}
        >
          <:col :let={client} label="Name">
            <div class="flex items-center gap-2">
              <span class="font-medium">{client.name}</span>
              <.badge :if={!client.gstin} variant="warning">no GSTIN</.badge>
            </div>
          </:col>
          <:col :let={client} label="Type">{client.type}</:col>
          <:col :let={client} label="Latest month">
            <span :if={client.month}>{period_label(client.month.period)}</span>
            <span :if={!client.month} class="text-ink-subtle">no months yet</span>
          </:col>
          <:col :let={client} label="Status">
            <.badge :if={client.month} variant={state_variant(client.month.state)}>
              {month_state_label(client.month.state)}
            </.badge>
            <span :if={!client.month} class="text-ink-faint">—</span>
          </:col>
          <:col :let={client} label="Needs a decision" align="right">
            <.badge :if={client.need_decision && client.need_decision > 0} variant="warning">
              {client.need_decision}
            </.badge>
            <span
              :if={!client.need_decision || client.need_decision == 0}
              class="text-ink-faint"
            >
              —
            </span>
          </:col>
          <:col :let={client} label="">
            <.link
              navigate={~p"/clients/#{client.id}/edit"}
              id={"client-edit-#{client.id}"}
              class="hover:text-ink text-fine text-ink-subtle"
              onclick="event.stopPropagation()"
            >
              Edit
            </.link>
          </:col>
          <:empty>
            <div id="clients-empty" class="space-y-block">
              <p>No clients yet.</p>
              <.button navigate={~p"/clients/new"} id="clients-add-first">
                Add your first client
              </.button>
            </div>
          </:empty>
        </.data_table>
      </div>
    </Layouts.app>
    """
  end
end
