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
      <div class="mx-auto flex min-h-screen max-w-md flex-col justify-center px-4 py-12 sm:px-6 lg:px-8">
        <div class="mb-section">
          <.link navigate={~p"/"} class="inline-flex items-center">
            <.logo class="text-base-content h-7 w-auto" />
          </.link>
          <div class="mt-section space-y-related">
            <h1 class="text-h4 font-semibold">Reset your password</h1>
            <p class="text-body text-ink-muted">
              Enter your work email and we'll send reset instructions if the account exists.
            </p>
          </div>
        </div>

        <.form
          for={@form}
          id="forgot-password-form"
          phx-submit="send_instructions"
          class="space-y-block"
        >
          <.input field={@form[:email]} type="email" label="Work email" required />
          <.button full_width>
            Send reset instructions
          </.button>
        </.form>

        <.link
          navigate={~p"/users/log_in"}
          class="mt-block text-primary text-ui inline-flex font-semibold"
        >
          Back to sign in
        </.link>
      </div>
    </main>
    """
  end
end
