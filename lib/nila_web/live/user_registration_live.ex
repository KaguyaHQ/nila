defmodule NilaWeb.UserRegistrationLive do
  use NilaWeb, :live_view

  alias Nila.Accounts

  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: registration_form(%{}), submit?: false, session_token: nil)}
  end

  def handle_event("validate", %{"signup" => params}, socket) do
    {:noreply, assign(socket, form: registration_form(params))}
  end

  def handle_event("save", %{"signup" => params}, socket) do
    case Accounts.register_user_with_org(params) do
      {:ok, %{user: user}} ->
        Accounts.deliver_user_confirmation_instructions(user, fn token ->
          url(~p"/users/confirm/#{token}")
        end)

        {:noreply,
         assign(socket,
           submit?: true,
           session_token: Accounts.generate_user_session_token(user)
         )}

      {:error, changeset} ->
        {:noreply,
         assign(socket, form: to_form(Map.put(changeset, :action, :insert), as: "signup"))}
    end
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
            <h1 class="text-h4 font-semibold">Create your firm</h1>
            <p class="text-body text-ink-muted">
              Start with your firm. You can invite the team later.
            </p>
          </div>
        </div>

        <.form
          for={@form}
          id="registration-form"
          action={~p"/users/sign_up"}
          phx-change="validate"
          phx-submit="save"
          phx-trigger-action={@submit?}
          class="space-y-block"
        >
          <input type="hidden" name="signup_session_token" value={@session_token} />
          <.input field={@form[:name]} label="Full name" required />
          <.input field={@form[:email]} type="email" label="Work email" required />
          <.input field={@form[:org_name]} label="Company name" required />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirm password"
            autocomplete="new-password"
            required
          />

          <.button class="w-full">
            Create firm
          </.button>
        </.form>

        <p class="mt-block text-body text-ink-muted">
          Already have an account?
          <.link navigate={~p"/users/log_in"} class="text-primary font-semibold">
            Sign in
          </.link>
        </p>
      </div>
    </main>
    """
  end

  defp registration_form(params) do
    params
    |> Accounts.change_user_registration_with_org()
    |> Map.put(:action, :validate)
    |> to_form(as: "signup")
  end
end
