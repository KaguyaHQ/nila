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

    <main class="min-h-screen bg-base-200 text-base-content">
      <div class="mx-auto flex min-h-screen max-w-md flex-col justify-center px-5 py-12">
        <div class="mb-8">
          <.link navigate={~p"/"} class="inline-flex items-center gap-2 text-small font-semibold">
            <span class="grid size-8 place-items-center rounded-field bg-primary text-white">
              <.icon name="hero-moon" class="size-4" />
            </span>
            Nila
          </.link>
        </div>

        <div :if={@user} id="invite-accept">
          <h1 class="text-h4 font-semibold">Welcome, {@user.name}</h1>
          <p class="mt-2 text-body text-base-content/70">
            Set a password to join the workspace and sign in.
          </p>

          <.form
            for={@form}
            id="invite-form"
            action={~p"/users/invite/#{@token}"}
            phx-change="validate"
            class="mt-6 space-y-4"
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

        <div :if={is_nil(@user)} id="invite-invalid">
          <h1 class="text-h4 font-semibold">This invite link is no longer valid</h1>
          <p class="mt-2 text-body text-base-content/70">
            It may have expired or already been used. Ask an owner to send a fresh
            invitation.
          </p>
          <.link
            navigate={~p"/users/log_in"}
            class="mt-6 inline-flex h-10 items-center justify-center rounded-field border border-base-300 bg-base-100 px-4 text-small font-semibold text-base-content/75 transition hover:border-base-300 hover:bg-base-200"
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
