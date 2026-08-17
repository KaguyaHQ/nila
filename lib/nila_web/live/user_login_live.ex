defmodule NilaWeb.UserLoginLive do
  use NilaWeb, :live_view

  @dev_login? Application.compile_env(:nila, :dev_routes, false)

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
            <h1 class="text-h4 font-semibold">Sign in</h1>
            <p class="text-ink-muted text-ui">Use your work email and password.</p>
          </div>
        </div>

        <.form for={@form} id="login-form" action={~p"/users/log_in"} class="space-y-block">
          <.input
            field={@form[:email]}
            type="email"
            label="Work email"
            autocomplete="username"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            required
          />
          <.link
            navigate={~p"/users/reset_password"}
            class="hover:text-primary/80 text-primary text-ui inline-flex font-semibold transition"
          >
            Forgot your password?
          </.link>

          <.input
            type="checkbox"
            id="user-remember-me"
            name="user[remember_me]"
            label="Keep me signed in"
            value={false}
          />

          <.button full_width>
            Sign in
          </.button>
        </.form>

        <p class="mt-block text-ink-muted text-ui">
          Interested in Nila?
          <.link navigate={~p"/contact"} class="text-primary font-semibold">
            Arrange a test
          </.link>
        </p>

        <section
          :if={@users != []}
          class="border-base-300 mt-section pt-block space-y-related border-t"
        >
          <p class="text-ink-subtle text-label font-semibold uppercase">
            Quick login
          </p>
          <div class="flex flex-wrap gap-2">
            <.form :for={user <- @users} for={%{}} action={~p"/users/log_in"} class="inline">
              <input type="hidden" name="dev_login" value="true" />
              <input type="hidden" name="email" value={user.email} />
              <.button type="submit" variant="outline" size="xs">
                {user.name}
              </.button>
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
