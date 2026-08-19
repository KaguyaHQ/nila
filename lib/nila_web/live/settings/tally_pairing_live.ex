defmodule NilaWeb.Settings.TallyPairingLive do
  use NilaWeb, :live_view

  alias Nila.TallyDevices

  @impl true
  def mount(%{"approval_code" => approval_code}, _session, socket) do
    pairing = TallyDevices.get_pairing_for_approval(approval_code)

    {:ok,
     socket
     |> assign(:page_title, "Link Tally computer")
     |> assign(:settings_section, :connectors)
     |> assign(:pairing_code, approval_code)
     |> assign_pairing(pairing)}
  end

  @impl true
  def handle_event("approve", _params, socket) do
    case TallyDevices.approve_pairing(
           socket.assigns.pairing_code,
           socket.assigns.current_scope
         ) do
      {:ok, pairing} ->
        {:noreply,
         socket
         |> assign(:pairing, pairing)
         |> assign(:pairing_state, :approved)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:pairing, nil)
         |> assign(:pairing_state, :unavailable)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.settings
      flash={@flash}
      current_scope={@current_scope}
      active_section={@settings_section}
    >
      <div id="tally-pairing" class="space-y-section max-w-2xl">
        <.settings_header title="Link this Tally computer">
          Approve the Windows computer that opened this page. Nila never stores your password in
          the connector.
        </.settings_header>

        <.card :if={@pairing_state == :pending} id="tally-pairing-pending">
          <div class="space-y-block">
            <div class="space-y-related">
              <p class="text-ink-subtle text-label font-semibold uppercase">Computer</p>
              <p id="tally-pairing-device-name" class="text-base-content text-h4 font-semibold">
                {@pairing.device_name}
              </p>
              <p class="text-body text-ink-muted">
                This computer will be able to connect to TallyPrime for <span class="text-base-content font-medium">{@current_scope.current_org.name}</span>.
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-3">
              <.button id="approve-tally-pairing" phx-click="approve" variant="primary">
                <.icon name="hero-link" class="size-4" /> Approve this computer
              </.button>
              <.link navigate={~p"/settings/connectors"} class="text-moon text-ui font-medium">
                Cancel
              </.link>
            </div>
          </div>
        </.card>

        <div :if={@pairing_state == :approved} id="tally-pairing-approved">
          <.callout kind="success" title="Computer approved">
            Return to Nila Connector. It will finish linking automatically.
          </.callout>
        </div>

        <div :if={@pairing_state == :unavailable} id="tally-pairing-unavailable">
          <.callout kind="warning" title="This pairing request is no longer available">
            Start linking again from Nila Connector to receive a new code.
          </.callout>
        </div>
      </div>
    </Layouts.settings>
    """
  end

  defp assign_pairing(socket, {:ok, pairing}) do
    socket
    |> assign(:pairing, pairing)
    |> assign(:pairing_state, :pending)
  end

  defp assign_pairing(socket, {:error, _reason}) do
    socket
    |> assign(:pairing, nil)
    |> assign(:pairing_state, :unavailable)
  end
end
