defmodule NilaWeb.UserLoginLive do
  use NilaWeb, :live_view

  @dev_login? Application.compile_env(:nila, :dev_routes, false)

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
          <h1 class="mt-8 text-h4 font-semibold">Sign in</h1>
          <p class="mt-2 text-small text-base-content/70">Use your work email and password.</p>
        </div>

        <.form for={@form} id="login-form" action={~p"/users/log_in"} class="space-y-4">
          <.input field={@form[:email]} type="email" label="Work email" required />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            required
          />
          <.link
            navigate={~p"/users/reset_password"}
            class="inline-flex text-small font-semibold text-primary transition hover:text-primary/80"
          >
            Forgot your password?
          </.link>

          <label class="flex items-center gap-2 text-small text-base-content/70">
            <input type="checkbox" name="user[remember_me]" value="true" class="rounded" />
            Keep me signed in
          </label>

          <.button class="w-full">
            Sign in
          </.button>
        </.form>

        <p class="mt-5 text-small text-base-content/70">
          New to Nila?
          <.link navigate={~p"/users/sign_up"} class="font-semibold text-primary">
            Create a workspace
          </.link>
        </p>

        <section :if={@users != []} class="mt-8 border-t border-base-300 pt-5">
          <p class="text-label font-semibold uppercase text-base-content/60">
            Quick login
          </p>
          <div class="mt-3 flex flex-wrap gap-2">
            <.form :for={user <- @users} for={%{}} action={~p"/users/log_in"} class="inline">
              <input type="hidden" name="dev_login" value="true" />
              <input type="hidden" name="email" value={user.email} />
              <button
                type="submit"
                class="rounded-full border border-base-300 bg-base-100 px-3 py-1.5 text-fine font-semibold text-base-content/75 shadow-moon transition hover:border-base-300 hover:bg-base-200"
              >
                {user.name}
              </button>
            </.form>
          </div>
        </section>
      </div>
    </main>
    """
  end

  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)

    socket =
      assign(socket,
        form: to_form(%{"email" => email}, as: "user"),
        users: quick_login_users()
      )

    {:ok, socket}
  end

  if @dev_login? do
    defp quick_login_users, do: Nila.Accounts.list_users() |> Enum.take(10)
  else
    defp quick_login_users, do: []
  end
end
