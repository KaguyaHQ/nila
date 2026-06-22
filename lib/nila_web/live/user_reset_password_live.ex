defmodule NilaWeb.UserResetPasswordLive do
  use NilaWeb, :live_view

  alias Nila.Accounts

  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.get_user_by_reset_password_token(token) do
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

  def handle_event("reset_password", %{"user" => params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, socket.assigns.token, params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Your password has been reset. Sign in with your new password.")
         |> push_navigate(to: ~p"/users/log_in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, to_form(Map.put(changeset, :action, :validate), as: "user"))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "This reset link is no longer valid.")
         |> push_navigate(to: ~p"/users/reset_password")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="bg-base-200 text-base-content min-h-screen">
      <div class="mx-auto flex min-h-screen max-w-md flex-col justify-center px-5 py-12">
        <div class="mb-8">
          <.link navigate={~p"/"} class="text-small inline-flex items-center gap-2 font-semibold">
            <span class="bg-primary rounded-field grid size-8 place-items-center text-white">
              <.icon name="hero-moon" class="size-4" />
            </span>
            Nila
          </.link>
        </div>

        <div :if={@user} id="reset-password-valid">
          <h1 class="text-h4 font-semibold">Choose a new password</h1>
          <p class="text-base-content/70 text-body mt-2">
            Use at least 8 characters. You'll sign in again after the reset.
          </p>

          <.form
            for={@form}
            id="reset-password-form"
            phx-change="validate"
            phx-submit="reset_password"
            class="mt-6 space-y-4"
          >
            <.input
              field={@form[:password]}
              type="password"
              label="New password"
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
              Reset password
            </.button>
          </.form>
        </div>

        <div :if={is_nil(@user)} id="reset-password-invalid">
          <h1 class="text-h4 font-semibold">This reset link is no longer valid</h1>
          <p class="text-base-content/70 text-body mt-2">
            It may have expired or already been used. Request a fresh reset link.
          </p>
          <.link
            navigate={~p"/users/reset_password"}
            class="bg-base-100 border-base-300 hover:bg-base-200 hover:border-base-300 rounded-field text-base-content/75 text-small mt-6 inline-flex h-10 items-center justify-center border px-4 font-semibold transition"
          >
            Request a new link
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
