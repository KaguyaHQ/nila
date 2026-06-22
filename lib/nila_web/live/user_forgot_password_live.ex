defmodule NilaWeb.UserForgotPasswordLive do
  use NilaWeb, :live_view

  alias Nila.Accounts

  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: "user"))}
  end

  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket) do
    Accounts.deliver_user_reset_password_instructions(email, fn token ->
      url(~p"/users/reset_password/#{token}")
    end)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "If your email exists in Nila, password reset instructions have been sent."
     )
     |> push_navigate(to: ~p"/users/log_in")}
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
          <h1 class="text-h4 mt-8 font-semibold">Reset your password</h1>
          <p class="text-base-content/70 text-body mt-2">
            Enter your work email and we'll send reset instructions if the account exists.
          </p>
        </div>

        <.form for={@form} id="forgot-password-form" phx-submit="send_instructions" class="space-y-4">
          <.input field={@form[:email]} type="email" label="Work email" required />
          <.button class="w-full">
            Send reset instructions
          </.button>
        </.form>

        <.link
          navigate={~p"/users/log_in"}
          class="text-primary text-small mt-5 inline-flex font-semibold"
        >
          Back to sign in
        </.link>
      </div>
    </main>
    """
  end
end
