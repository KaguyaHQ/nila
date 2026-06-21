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
          Your personal account details for this workspace.
        </.page_header>

        <.card class="space-y-5">
          <div class="flex items-center gap-4">
            <div class="grid size-14 shrink-0 place-items-center rounded-field bg-primary text-body font-semibold text-primary-content shadow-moon">
              {user_initials(@current_scope.user)}
            </div>
            <div class="min-w-0">
              <h2 id="profile-name" class="truncate text-h4 font-semibold text-base-content">
                {@current_scope.user.name}
              </h2>
              <p id="profile-email" class="truncate text-small text-base-content/60">
                {@current_scope.user.email}
              </p>
            </div>
          </div>

          <div class="border-t border-base-300 pt-5">
            <.link
              id="profile-account-settings-link"
              navigate={~p"/settings/account"}
              class="inline-flex h-10 items-center justify-center rounded-field border border-base-300 bg-base-100 px-4 text-small font-semibold text-base-content/75 transition hover:border-base-300 hover:bg-base-200"
            >
              Manage account settings
            </.link>
          </div>

          <dl class="grid gap-4 border-t border-base-300 pt-5 sm:grid-cols-2">
            <div>
              <dt class="text-label font-medium uppercase text-base-content/50">
                Workspace
              </dt>
              <dd id="profile-workspace" class="mt-1 text-small font-semibold text-base-content">
                {workspace_name(@current_scope)}
              </dd>
            </div>
            <div>
              <dt class="text-label font-medium uppercase text-base-content/50">
                Role
              </dt>
              <dd id="profile-role" class="mt-1 text-small font-semibold text-base-content">
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
