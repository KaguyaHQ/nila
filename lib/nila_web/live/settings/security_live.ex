defmodule NilaWeb.Settings.SecurityLive do
  use NilaWeb, :live_view

  alias Nila.Accounts

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Security")
      |> assign(:settings_section, :security)
      |> assign_password_form(%{})

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_password", %{"password_user" => params}, socket) do
    {:noreply, assign_password_form(socket, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.settings
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      active_section={@settings_section}
    >
      <div id="settings-security" class="space-y-6">
        <.settings_header title="Security">
          Manage how you sign in to Nila.
        </.settings_header>

        <.settings_panel
          title="Change password"
          description="We'll sign out other sessions after your password changes."
        >
          <.form
            for={@password_form}
            id="change-password-form"
            action={~p"/settings/security/password"}
            phx-change="validate_password"
            class="space-y-4"
          >
            <.input
              field={@password_form[:current_password]}
              type="password"
              label="Current password"
              required
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              minlength="12"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              required
            />
            <.button>
              Update password
            </.button>
          </.form>
        </.settings_panel>
      </div>
    </Layouts.settings>
    """
  end

  defp assign_password_form(socket, params) do
    form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(params)
      |> Map.put(:action, :validate)
      |> to_form(as: "password_user")

    assign(socket, :password_form, form)
  end
end
