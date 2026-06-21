defmodule NilaWeb.UserSettingsLive do
  use NilaWeb, :live_view

  alias Nila.Accounts

  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Account settings")
      |> assign_forms(%{}, %{})
      |> maybe_confirm_email(params)

    {:ok, socket}
  end

  def handle_event("validate_password", %{"password_user" => params}, socket) do
    {:noreply,
     assign(socket, :password_form, password_form(socket.assigns.current_scope.user, params))}
  end

  def handle_event("validate_email", %{"email_user" => params}, socket) do
    {:noreply, assign(socket, :email_form, email_form(socket.assigns.current_scope.user, params))}
  end

  def handle_event("update_email", %{"email_user" => params}, socket) do
    user = socket.assigns.current_scope.user
    current_password = Map.get(params, "current_password", "")

    case Accounts.deliver_user_update_email_instructions(
           user,
           current_password,
           params,
           fn token ->
             url(~p"/settings/account/confirm_email/#{token}")
           end
         ) do
      {:ok, email} ->
        {:noreply,
         socket
         |> put_flash(:info, "A confirmation link has been sent to #{email}.")
         |> assign(:email_form, email_form(user, %{}))}

      {:error, changeset} ->
        {:noreply,
         assign(
           socket,
           :email_form,
           to_form(Map.put(changeset, :action, :validate), as: "email_user")
         )}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="account-settings-page" class="mx-auto max-w-3xl space-y-6">
        <.page_header eyebrow="Account" title="Account settings">
          Manage your email and password.
        </.page_header>

        <.card class="space-y-5">
          <div>
            <h2 class="text-h4 font-semibold text-base-content">Change password</h2>
            <p class="mt-1 text-small text-base-content/60">
              We'll sign out other sessions after your password changes.
            </p>
          </div>

          <.form
            for={@password_form}
            id="change-password-form"
            action={~p"/settings/account/password"}
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
        </.card>

        <.card class="space-y-5">
          <div>
            <h2 class="text-h4 font-semibold text-base-content">Change email</h2>
            <p class="mt-1 text-small text-base-content/60">
              We'll send a confirmation link to your new email address.
            </p>
          </div>

          <.form
            for={@email_form}
            id="change-email-form"
            phx-change="validate_email"
            phx-submit="update_email"
            class="space-y-4"
          >
            <.input field={@email_form[:email]} type="email" label="New email" required />
            <.input
              field={@email_form[:current_password]}
              type="password"
              label="Current password"
              required
            />
            <.button>
              Send confirmation link
            </.button>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp maybe_confirm_email(socket, %{"token" => token}) do
    case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
      {:ok, user} ->
        socket
        |> put_flash(:info, "Your email has been updated.")
        |> assign(:current_scope, %{socket.assigns.current_scope | user: user})
        |> push_navigate(to: ~p"/settings/account")

      {:error, _reason} ->
        socket
        |> put_flash(:error, "Email change link is invalid or expired.")
        |> push_navigate(to: ~p"/settings/account")
    end
  end

  defp maybe_confirm_email(socket, _params), do: socket

  defp assign_forms(socket, password_params, email_params) do
    user = socket.assigns.current_scope.user

    socket
    |> assign(:password_form, password_form(user, password_params))
    |> assign(:email_form, email_form(user, email_params))
  end

  defp password_form(user, params) do
    user
    |> Accounts.change_user_password(params)
    |> Map.put(:action, :validate)
    |> to_form(as: "password_user")
  end

  defp email_form(user, params) do
    user
    |> Accounts.change_user_email(params)
    |> Map.put(:action, :validate)
    |> to_form(as: "email_user")
  end
end
