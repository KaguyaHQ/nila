defmodule NilaWeb.ProfileLive do
  use NilaWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Profile")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="profile-page" class="mx-auto max-w-3xl space-y-6">
        <.page_header eyebrow="Account" title="Profile">
          Your personal account details for this firm.
        </.page_header>

        <.card class="space-y-5">
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

          <div class="border-base-300 border-t pt-5">
            <.link
              id="profile-account-settings-link"
              navigate={~p"/settings/account"}
              class="bg-base-100 border-base-300 hover:bg-base-200 hover:border-base-300 rounded-field text-base-content/75 text-small inline-flex h-10 items-center justify-center border px-4 font-semibold transition"
            >
              Manage account settings
            </.link>
          </div>

          <dl class="border-base-300 grid gap-4 border-t pt-5 sm:grid-cols-2">
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
        </.card>
      </div>
    </Layouts.app>
    """
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
