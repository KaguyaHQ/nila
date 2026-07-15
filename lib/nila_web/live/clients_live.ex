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

  defp list_clients(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}),
    do: Clients.list_clients(org_id)

  defp list_clients(_socket), do: []

  defp type_label(type), do: type |> to_string() |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="clients-page" class="mx-auto max-w-5xl space-y-6">
        <.page_header eyebrow="Clients" title="Clients">
          The businesses whose GST you file. Add a client before uploading their bills so
          the worked month files under the right party.
          <:actions>
            <.button navigate={~p"/clients/new"} id="clients-add">Add client</.button>
          </:actions>
        </.page_header>

        <.data_table
          id="clients-table"
          rows={@clients}
          row_id={fn client -> "client-#{client.id}" end}
          row_click={fn client -> JS.navigate(~p"/clients/#{client.id}/edit") end}
          empty?={@clients == []}
        >
          <:col :let={client} label="Name">{client.name}</:col>
          <:col :let={client} label="Type">{type_label(client.type)}</:col>
          <:col :let={client} label="GSTIN">{client.gstin}</:col>
          <:col :let={client} label="PAN">{client.pan}</:col>
          <:empty>No clients yet.</:empty>
        </.data_table>
      </div>
    </Layouts.app>
    """
  end
end
