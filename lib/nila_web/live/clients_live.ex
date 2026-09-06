defmodule NilaWeb.ClientsLive do
  use NilaWeb, :live_view

  alias Nila.Clients

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Clients")
     |> assign(:clients, list_clients(socket))}
  end

  defp list_clients(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    Clients.list_clients(org_id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="clients-page" class="pb-section space-y-block mx-auto w-full max-w-[960px]">
        <.page_header title="Clients">
          <:actions>
            <.button navigate={~p"/clients/new"} id="clients-add" variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> Add client
            </.button>
          </:actions>
        </.page_header>

        <.card padding="none">
          <div class="px-4 py-3">
            <.data_table
              id="clients-table"
              rows={@clients}
              row_id={fn client -> "client-#{client.id}" end}
              row_navigate={fn client -> ~p"/clients/#{client.id}/edit" end}
              row_label={fn client -> "Edit #{client.name}" end}
              empty?={@clients == []}
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
                  <p>No clients yet.</p>

                  <.button navigate={~p"/clients/new"} id="clients-add-first">
                    <.icon name="hero-plus" class="size-4" /> Add your first client
                  </.button>
                </div>
              </:empty>
            </.data_table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
