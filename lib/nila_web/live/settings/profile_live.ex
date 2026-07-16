defmodule NilaWeb.Settings.ProfileLive do
  use NilaWeb, :live_view

  alias Nila.Accounts

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Profile")
      |> assign(:settings_section, :profile)
      |> assign_name_form(%{})
      |> assign_email_form(%{})
      |> maybe_confirm_email(params)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_name", %{"name_user" => params}, socket) do
    {:noreply, assign_name_form(socket, Map.take(params, ["name"]))}
  end

  @impl true
  def handle_event("update_name", %{"name_user" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user(user, Map.take(params, ["name"])) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Name updated.")
         |> assign(:current_scope, %{socket.assigns.current_scope | user: user})
         |> assign_name_form(%{})}

      {:error, changeset} ->
        {:noreply,
         assign(
           socket,
           :name_form,
           to_form(Map.put(changeset, :action, :validate), as: "name_user")
         )}
    end
  end

  @impl true
  def handle_event("validate_email", %{"email_user" => params}, socket) do
    {:noreply, assign_email_form(socket, params)}
  end

  @impl true
  def handle_event("update_email", %{"email_user" => params}, socket) do
    user = socket.assigns.current_scope.user
    current_password = Map.get(params, "current_password", "")

    case Accounts.deliver_user_update_email_instructions(
           user,
           current_password,
           params,
           fn token ->
             url(~p"/settings/profile/confirm_email/#{token}")
           end
         ) do
      {:ok, email} ->
        {:noreply,
         socket
         |> put_flash(:info, "A confirmation link has been sent to #{email}.")
         |> assign_email_form(%{})}

      {:error, changeset} ->
        {:noreply,
         assign(
           socket,
           :email_form,
           to_form(Map.put(changeset, :action, :validate), as: "email_user")
         )}
    end
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
      <div id="settings-profile" class="space-y-6">
        <.settings_header title="Profile">
          Your personal account details for this firm.
        </.settings_header>

        <.settings_panel>
          <div class="flex items-center gap-4">
            <div class="bg-primary rounded-field shadow-moon text-body text-primary-content grid size-14 shrink-0 place-items-center font-semibold">
              {user_initials(@current_scope.user)}
            </div>
            <div class="min-w-0">
              <h2 id="profile-name" class="text-base-content text-h4 truncate font-semibold">
                {@current_scope.user.name}
              </h2>
              <p id="profile-email" class="text-base-content/60 text-small truncate">
                {@current_scope.user.email}
              </p>
            </div>
          </div>

          <dl class="border-base-300 mt-5 grid gap-4 border-t pt-5 sm:grid-cols-2">
            <div>
              <dt class="text-base-content/50 text-label font-medium uppercase">
                Firm
              </dt>
              <dd id="profile-workspace" class="text-base-content text-small mt-1 font-semibold">
                {workspace_name(@current_scope)}
              </dd>
            </div>
            <div>
              <dt class="text-base-content/50 text-label font-medium uppercase">
                Role
              </dt>
              <dd id="profile-role" class="text-base-content text-small mt-1 font-semibold">
                {role_label(@current_scope)}
              </dd>
            </div>
          </dl>
        </.settings_panel>

        <.settings_panel title="Change name" description="How your name appears across the firm.">
          <.form
            for={@name_form}
            id="change-name-form"
            phx-change="validate_name"
            phx-submit="update_name"
            class="space-y-4"
          >
            <.input field={@name_form[:name]} label="Name" required />
            <.button>
              Update name
            </.button>
          </.form>
        </.settings_panel>

        <.settings_panel
          title="Change email"
          description="We'll send a confirmation link to your new email address."
        >
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
        </.settings_panel>
      </div>
    </Layouts.settings>
    """
  end

  defp maybe_confirm_email(socket, %{"token" => token}) do
    case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
      {:ok, user} ->
        socket
        |> put_flash(:info, "Your email has been updated.")
        |> assign(:current_scope, %{socket.assigns.current_scope | user: user})
        |> push_navigate(to: ~p"/settings/profile")

      {:error, _reason} ->
        socket
        |> put_flash(:error, "Email change link is invalid or expired.")
        |> push_navigate(to: ~p"/settings/profile")
    end
  end

  defp maybe_confirm_email(socket, _params), do: socket

  defp assign_name_form(socket, params) do
    form =
      socket.assigns.current_scope.user
      |> Accounts.change_user(params)
      |> Map.put(:action, :validate)
      |> to_form(as: "name_user")

    assign(socket, :name_form, form)
  end

  defp assign_email_form(socket, params) do
    form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(params)
      |> Map.put(:action, :validate)
      |> to_form(as: "email_user")

    assign(socket, :email_form, form)
  end

  defp workspace_name(%{current_org: %{name: name}}) when name not in [nil, ""], do: name
  defp workspace_name(_scope), do: "Personal"

  defp role_label(%{membership: %{role: role}}) when is_binary(role) do
    role
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp role_label(_scope), do: "Personal"

  defp user_initials(%{name: name}) when is_binary(name) do
    name
    |> String.split()
    |> Enum.take(2)
    |> Enum.map_join("", &(String.first(&1) || ""))
    |> String.upcase()
  end

  defp user_initials(_user), do: "U"
end
