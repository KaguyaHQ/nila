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

    <main class="min-h-screen bg-base-200 text-base-content">
      <div class="mx-auto flex min-h-screen max-w-md flex-col justify-center px-5 py-12">
        <div class="mb-8">
          <.link navigate={~p"/"} class="inline-flex items-center gap-2 text-small font-semibold">
            <span class="grid size-8 place-items-center rounded-field bg-primary text-white">
              <.icon name="hero-moon" class="size-4" />
            </span>
            Nila
          </.link>
          <h1 class="mt-8 text-h4 font-semibold">Create your workspace</h1>
          <p class="mt-2 text-body text-base-content/70">
            Start with your company workspace. You can invite the team later.
          </p>
        </div>

        <.form
          for={@form}
          id="registration-form"
          action={~p"/users/sign_up"}
          phx-change="validate"
          phx-submit="save"
          phx-trigger-action={@submit?}
          class="space-y-4"
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
            Create workspace
          </.button>
        </.form>

        <p class="mt-5 text-body text-base-content/70">
          Already have an account?
          <.link navigate={~p"/users/log_in"} class="font-semibold text-primary">
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
