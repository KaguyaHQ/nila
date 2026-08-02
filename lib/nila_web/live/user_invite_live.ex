defmodule NilaWeb.UserInviteLive do
  use NilaWeb, :live_view

  alias Nila.Accounts

  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.get_user_by_invite_token(token) do
        nil ->
          socket
          |> assign(:token, token)
          |> assign(:user, nil)
          |> assign(:form, nil)

        user ->
          socket
          |> assign(:token, token)
          |> assign(:user, user)
          |> assign(:form, password_form(user, %{}))
      end

    {:ok, socket}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply, assign(socket, :form, password_form(socket.assigns.user, params))}
  end

  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="bg-base-200 text-base-content min-h-screen">
      <div class="mx-auto flex min-h-screen max-w-md flex-col justify-center px-4 py-12 sm:px-6 lg:px-8">
        <div class="mb-section">
          <.link navigate={~p"/"} class="inline-flex items-center">
            <.logo class="text-base-content h-7 w-auto" />
          </.link>
        </div>

        <div :if={@user} id="invite-accept" class="space-y-section">
          <div class="space-y-related">
            <h1 class="text-h4 font-semibold">Set up your Nila workspace</h1>
            <p class="text-body text-ink-muted">
              Welcome, {@user.name}. Your firm has invited you to Nila. Create your password to
              continue.
            </p>
          </div>

          <.form
            for={@form}
            id="invite-form"
            action={~p"/users/invite/#{@token}"}
            phx-change="validate"
            class="space-y-block"
          >
            <.input
              field={@form[:password]}
              type="password"
              label="Create a password"
              minlength="12"
              required
            />
            <.input
              field={@form[:password_confirmation]}
              type="password"
              label="Confirm password"
              required
            />

            <.button class="w-full">
              Set password and sign in
            </.button>
          </.form>
        </div>

        <div :if={is_nil(@user)} id="invite-invalid" class="space-y-section">
          <div class="space-y-related">
            <h1 class="text-h4 font-semibold">This invite link is no longer valid</h1>
            <p class="text-body text-ink-muted">
              It may have expired or already been used. Ask an owner to send a fresh
              invitation.
            </p>
          </div>
          <.link
            navigate={~p"/users/log_in"}
            class="bg-base-100 border-base-300 hover:bg-base-200 hover:border-base-300 rounded-field text-ink-muted text-ui inline-flex h-10 items-center justify-center border px-4 font-semibold transition"
          >
            Go to sign in
          </.link>
        </div>
      </div>
    </main>
    """
  end

  defp password_form(user, params) do
    user
    |> Accounts.change_user_password(params)
    |> Map.put(:action, :validate)
    |> to_form(as: "user")
  end
end
