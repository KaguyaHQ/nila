defmodule NilaWeb.ClientsLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.TallyDevices

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Clients")
     |> assign(:clients, list_clients(socket))}
  end

  defp list_clients(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    company_by_client =
      org_id
      |> TallyDevices.list_linked_companies()
      |> Map.new(&{&1.client.id, &1})

    org_id
    |> Clients.list_clients()
    |> Enum.map(fn client ->
      %{
        id: client.id,
        name: client.name,
        gstin: client.gstin,
        tally_company: tally_company_label(company_by_client[client.id])
      }
    end)
  end

  defp tally_company_label(nil), do: nil
  defp tally_company_label(company), do: company.name

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="clients-page" class="space-y-section mx-auto max-w-5xl">
        <.page_header eyebrow="Clients" title="Clients">
          Businesses Nila works for and their Tally connections.
          <:actions>
            <.button navigate={~p"/clients/new"} id="clients-add">
              <.icon name="hero-plus" class="size-4" /> Add client
            </.button>
          </:actions>
        </.page_header>

        <.data_table
          id="clients-table"
          rows={@clients}
          row_id={fn client -> "client-#{client.id}" end}
          empty?={@clients == []}
          mode="worklist"
        >
          <:col :let={client} label="Client" row_header>
            <span class="font-medium">{client.name}</span>
          </:col>
          <:col :let={client} label="GSTIN">
            <span :if={client.gstin} class="whitespace-nowrap">{client.gstin}</span>
            <span :if={!client.gstin} class="text-ink-muted">—</span>
          </:col>
          <:col :let={client} label="Tally company">
            <span :if={client.tally_company}>{client.tally_company}</span>
            <span :if={!client.tally_company} class="text-ink-muted">Not connected</span>
          </:col>
          <:col :let={client} label="" class="whitespace-nowrap">
            <div class="flex justify-end">
              <.button
                navigate={~p"/clients/#{client.id}/edit"}
                id={"client-edit-#{client.id}"}
                variant="ghost"
                size="xs"
                aria-label={"Edit #{client.name}"}
              >
                Edit <.icon name="hero-arrow-right" class="size-4" />
              </.button>
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
    </Layouts.app>
    """
  end
end
