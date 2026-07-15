defmodule NilaWeb.ClientEditLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Clients.Client

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    org = socket.assigns.current_scope.current_org

    case Clients.get_client(org.id, id) do
      {:ok, client} ->
        {:ok,
         socket
         |> assign(:page_title, "Edit client")
         |> assign(:client, client)
         |> assign(:form, to_form(Clients.change_client(client)))}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Client not found.")
         |> push_navigate(to: ~p"/clients")}
    end
  end

  @impl true
  def handle_event("validate", %{"client" => params}, socket) do
    changeset =
      socket.assigns.client
      |> Clients.change_client(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"client" => params}, socket) do
    case Clients.update_client(socket.assigns.client, params) do
      {:ok, _client} ->
        {:noreply,
         socket
         |> put_flash(:info, "Client updated.")
         |> push_navigate(to: ~p"/clients")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp type_options do
    Enum.map(Client.types(), &{String.capitalize(&1), &1})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="client-edit-page" class="mx-auto max-w-2xl space-y-6">
        <.page_header eyebrow="Clients" title="Edit client">
          A first-class party you file GST for. Name and type are required; GSTIN and PAN
          are validated when provided.
        </.page_header>

        <.card>
          <.form for={@form} id="client-form" phx-change="validate" phx-submit="save">
            <div class="space-y-5">
              <.input field={@form[:name]} label="Name" required />
              <.input
                field={@form[:type]}
                type="select"
                label="Type"
                prompt="Select a type"
                options={type_options()}
              />
              <.input field={@form[:gstin]} label="GSTIN" />
              <.input field={@form[:pan]} label="PAN" />
              <.input field={@form[:phone]} label="Phone" />

              <div class="flex items-center gap-3">
                <.button type="submit" id="client-submit">Save changes</.button>
                <.link
                  navigate={~p"/clients"}
                  id="client-cancel"
                  class="text-base-content/70 text-small font-semibold"
                >
                  Cancel
                </.link>
              </div>
            </div>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
