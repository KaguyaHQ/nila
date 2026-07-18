defmodule NilaWeb.ClientNewLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Clients.Client

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Add client")
     |> assign(:form, to_form(Clients.change_client(%Client{})))}
  end

  @impl true
  def handle_event("validate", %{"client" => params}, socket) do
    changeset =
      %Client{}
      |> Clients.change_client(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"client" => params}, socket) do
    org = socket.assigns.current_scope.current_org
    attrs = Map.put(params, "org_id", org.id)

    case Clients.create_client(attrs) do
      {:ok, client} ->
        {:noreply,
         socket
         |> put_flash(:info, "Client added — now bring in their documents.")
         |> push_navigate(to: ~p"/gst/upload?client_id=#{client.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp type_options do
    Enum.map(Client.types(), &{String.capitalize(&1), &1})
  end

  defp chase_channel_options do
    [
      {"We'll send asks ourselves", "none"},
      {"WhatsApp", "whatsapp"},
      {"Email", "email"}
    ]
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
      <div id="client-new-page" class="mx-auto max-w-2xl space-y-6">
        <.page_header eyebrow="Clients" title="Add client">
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
              <.input field={@form[:email]} type="email" label="Email" />
              <.input
                field={@form[:chase_channel]}
                type="select"
                label="How should Nila ask for documents?"
                options={chase_channel_options()}
              />

              <div class="flex items-center gap-3">
                <.button type="submit" id="client-submit">Add client</.button>
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
