defmodule NilaWeb.Gst.ConnectionComponent do
  @moduledoc "Shared in-place GST authentication. The parent resumes the requested task after verification."
  use NilaWeb, :live_component
  alias Nila.Accounts.Policy
  alias Nila.Gst.Portal

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open: false,
       client: nil,
       challenge: nil,
       busy: false,
       error: nil,
       otp_notice: nil,
       continuation: nil,
       return_focus: nil,
       connection_form: to_form(%{"username" => ""}, as: :connection),
       otp_form: to_form(%{}, as: :verification)
     )}
  end

  @impl true
  def update(%{request: _request}, %{assigns: %{busy: true}} = socket), do: {:ok, socket}

  def update(%{request: request}, socket) do
    scope = socket.assigns.current_scope

    with true <- Policy.can?(scope, :manage_connectors),
         {:ok, client} <- Nila.Clients.get_client(scope.current_org.id, request.client_id),
         true <- Nila.Gstin.valid?(client.gstin) do
      connection =
        case Portal.connection(scope.current_org.id, client.id) do
          {:ok, value} -> value
          _ -> nil
        end

      challenge = socket.assigns.challenge

      resume? =
        challenge && challenge.client_id == client.id &&
          challenge.account.gstin == client.gstin &&
          DateTime.diff(DateTime.utc_now(), challenge.requested_at) in 0..899

      username =
        if resume?,
          do: challenge.account.username,
          else: if(connection, do: connection.username, else: client.gst_username || "")

      {:ok,
       assign(socket,
         open: true,
         client: client,
         error: nil,
         otp_notice: nil,
         challenge: if(resume?, do: challenge),
         continuation: request.continuation,
         return_focus: request.return_focus,
         connection_form: to_form(%{"username" => username}, as: :connection),
         otp_form: to_form(%{}, as: :verification)
       )}
    else
      _ -> {:ok, socket}
    end
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("close", _, %{assigns: %{busy: false}} = socket),
    do: {:noreply, assign(socket, open: false, otp_form: to_form(%{}, as: :verification))}

  def handle_event(
        "request_otp",
        %{"connection" => %{"username" => username}},
        %{assigns: %{busy: false, open: true}} = socket
      ) do
    scope = socket.assigns.current_scope
    client_id = socket.assigns.client.id

    {:noreply,
     socket
     |> assign(
       busy: true,
       error: nil,
       connection_form: to_form(%{"username" => username}, as: :connection)
     )
     |> start_async(:request_otp, fn -> Portal.request_otp(scope, client_id, username) end)}
  end

  def handle_event(
        "verify_otp",
        %{"verification" => %{"otp" => otp}},
        %{assigns: %{busy: false, open: true, challenge: challenge}} = socket
      )
      when not is_nil(challenge) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(busy: true, error: nil)
     |> start_async(:verify_otp, fn -> Portal.verify_otp(scope, challenge, otp) end)}
  end

  def handle_event(
        "resend_otp",
        _,
        %{assigns: %{busy: false, open: true, challenge: challenge}} = socket
      )
      when not is_nil(challenge) do
    scope = socket.assigns.current_scope
    client_id = socket.assigns.client.id
    username = challenge.account.username

    {:noreply,
     socket
     |> assign(busy: true, error: nil, otp_notice: nil)
     |> start_async(:resend_otp, fn -> Portal.request_otp(scope, client_id, username) end)}
  end

  def handle_event("change_username", _, %{assigns: %{busy: false, open: true}} = socket),
    do:
      {:noreply,
       assign(socket,
         challenge: nil,
         error: nil,
         otp_notice: nil,
         otp_form: to_form(%{}, as: :verification)
       )}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:request_otp, {:ok, {:ok, challenge}}, socket),
    do: {:noreply, assign(socket, busy: false, challenge: challenge)}

  def handle_async(:resend_otp, {:ok, {:ok, challenge}}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         challenge: challenge,
         otp_notice: "New OTP sent.",
         otp_form: to_form(%{}, as: :verification)
       )}

  def handle_async(:verify_otp, {:ok, {:ok, connection}}, socket) do
    send(self(), {:gst_connected, connection.client_id, socket.assigns.continuation})

    {:noreply,
     assign(socket,
       busy: false,
       open: false,
       challenge: nil,
       otp_form: to_form(%{}, as: :verification)
     )}
  end

  def handle_async(_, {:ok, {:error, reason}}, socket) do
    expired? =
      socket.assigns.challenge &&
        DateTime.diff(DateTime.utc_now(), socket.assigns.challenge.requested_at) >= 900

    message =
      if expired?,
        do: "This OTP request expired. Request a new OTP.",
        else: error_message(reason)

    {:noreply,
     assign(socket,
       busy: false,
       error: message,
       challenge: if(expired?, do: nil, else: socket.assigns.challenge),
       otp_form: to_form(%{}, as: :verification)
     )}
  end

  def handle_async(_, {:exit, _}, socket),
    do: {:noreply, assign(socket, busy: false, error: "GST could not be reached. Try again.")}

  defp verify_label({:fetch_2b, _}), do: "Verify and fetch"
  defp verify_label(:check_notices), do: "Verify and check notices"
  defp verify_label(_), do: "Verify and connect"

  defp error_message(:not_configured),
    do: "GST access is not configured. Ask the workspace owner to finish setup."

  defp error_message(:forbidden), do: "Your role cannot manage GST connections."

  defp error_message(:invalid_connection),
    do: "Check the GST username and six-digit OTP. You may need to request a new OTP."

  defp error_message({:provider, _}),
    do: "GST rejected this request. Check the username and OTP, or request a new OTP."

  defp error_message(_), do: "GST could not complete the connection. Try again."

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.modal
        :if={@open}
        id="gst-connection-modal"
        title={"Connect GST · #{@client.name}"}
        on_close="close"
        target={@myself}
        close_on_escape={!@busy}
        return_focus={@return_focus}
      >
        <div class="space-y-block">
          <div class="gap-x-block gap-y-related text-ink-muted text-ui flex flex-wrap">
            <p id="gst-connection-identity">GSTIN: {@client.gstin}</p>
            <p :if={@challenge}>Username: {@challenge.account.username}</p>
          </div>
          <p :if={@error} id="gst-connection-error" role="alert" class="text-error text-ui">
            {@error}
          </p>
          <%= if @challenge do %>
            <.form
              for={@otp_form}
              id="gst-otp-form"
              phx-submit="verify_otp"
              phx-target={@myself}
              class="space-y-related"
            >
              <p id="gst-otp-instruction" class="text-ui">
                Enter the OTP sent to the client's registered phone or email.
              </p>
              <.input
                field={@otp_form[:otp]}
                id="gst-otp"
                label="OTP"
                required
                pattern="[0-9]{6}"
                minlength="6"
                maxlength="6"
                inputmode="numeric"
                autocomplete="one-time-code"
                aria-describedby="gst-otp-instruction"
                disabled={@busy}
              />
            </.form>
            <div class="gap-related flex flex-wrap items-center">
              <.button
                id="gst-otp-resend"
                variant="ghost"
                phx-click="resend_otp"
                phx-target={@myself}
                disabled={@busy}
              >Resend OTP</.button>
              <.button
                id="gst-change-username"
                variant="ghost"
                phx-click="change_username"
                phx-target={@myself}
                disabled={@busy}
              >Change username</.button>
              <span :if={@otp_notice} id="gst-otp-notice" role="status" class="text-ink-muted text-ui">{@otp_notice}</span>
            </div>
          <% else %>
            <.form
              for={@connection_form}
              id="gst-connect-form"
              phx-submit="request_otp"
              phx-target={@myself}
            >
              <.input
                field={@connection_form[:username]}
                id="gst-username"
                label="GST portal username"
                required
                maxlength="100"
                disabled={@busy}
              />
            </.form>
          <% end %>
        </div>
        <:footer>
          <.button
            id="gst-connection-close"
            phx-click="close"
            phx-target={@myself}
            variant="ghost"
            disabled={@busy}
          >Close</.button>
          <.button
            id="gst-connect-submit"
            type="submit"
            form={if @challenge, do: "gst-otp-form", else: "gst-connect-form"}
            disabled={@busy}
          >
            {cond do
              @busy -> "Please wait…"
              @challenge -> verify_label(@continuation)
              true -> "Send OTP"
            end}
          </.button>
        </:footer>
      </.modal>
    </div>
    """
  end
end
