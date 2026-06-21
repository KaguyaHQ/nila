defmodule NilaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use NilaWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :page_title, :string, default: nil
  attr :current_path, :string, default: nil, doc: "drives the active sidebar highlight"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div
      id="app-shell"
      class="group/app min-h-screen moonlight-night text-base-100/90"
      data-rail-collapsed="false"
    >
      <div id="rail-collapse-state" phx-hook="RailCollapse" phx-update="ignore" class="hidden"></div>

      <aside class="fixed inset-y-0 left-0 z-40 hidden w-64 flex-col px-3 py-4 transition-[width] duration-200 print:hidden lg:flex group-data-[rail-collapsed=true]/app:w-16">
        <div class="flex items-center justify-between gap-2 px-1 group-data-[rail-collapsed=true]/app:justify-center group-data-[rail-collapsed=true]/app:gap-0 group-data-[rail-collapsed=true]/app:px-0">
          <.link
            navigate={~p"/today"}
            class="flex min-w-0 items-center group-data-[rail-collapsed=true]/app:hidden"
          >
            <.logo class="h-5 w-auto text-base-100" />
          </.link>

          <button
            type="button"
            id="rail-collapse-toggle"
            class="grid size-8 shrink-0 place-items-center rounded-field text-base-100/55 transition hover:bg-base-100/10 hover:text-base-100 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-100/40"
            aria-label="Toggle navigation"
            data-rail-toggle
          >
            <.icon name="nila-panel-left" class="size-4" />
          </button>
        </div>

        <nav class="mt-5 flex flex-1 flex-col gap-6 overflow-y-auto">
          <div class="space-y-1">
            <.rail_link
              href={~p"/today"}
              icon="hero-inbox-stack"
              label="Today"
              current_path={@current_path}
            />
            <.rail_link
              href={~p"/assistant"}
              icon="hero-chat-bubble-left-ellipsis"
              label="Assistant"
              current_path={@current_path}
            />
          </div>
        </nav>

        <div :if={@current_scope} class="mt-4 border-t border-base-100/10 pt-3">
          <.account_menu current_scope={@current_scope} placement={:rail} id_prefix="layout" />
        </div>
      </aside>

      <div class="lg:pl-64 lg:transition-[padding] lg:duration-200 group-data-[rail-collapsed=true]/app:lg:pl-16">
        <div class="h-screen lg:p-3">
          <div class="flex h-full flex-col overflow-hidden bg-base-200 text-base-content lg:rounded-box lg:shadow-moon-lg lg:ring-1 lg:ring-white/40">
            <header class="z-30 shrink-0 border-b border-base-300 bg-base-100/80 px-4 py-2.5 backdrop-blur print:hidden sm:px-6 lg:px-8">
              <div class="flex items-center justify-between gap-4">
                <nav
                  aria-label="Breadcrumb"
                  class="flex min-w-0 items-center gap-1.5 text-small text-base-content/60"
                >
                  <span class="font-medium text-base-content/75">Nila</span>
                  <span :if={@page_title} class="text-base-content/30">/</span>
                  <span :if={@page_title} class="truncate font-medium text-base-content">
                    {@page_title}
                  </span>
                </nav>
                <div class="flex items-center gap-2">
                  <div :if={@current_scope} class="lg:hidden">
                    <.account_menu
                      current_scope={@current_scope}
                      placement={:header}
                      id_prefix="mobile"
                    />
                  </div>
                </div>
              </div>
            </header>

            <main class="flex-1 overflow-y-auto px-4 py-6 sm:px-6 lg:px-8">
              <div class="mx-auto max-w-[1480px]">
                {render_slot(@inner_block)}
              </div>
            </main>
          </div>
        </div>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :page_title, :string, default: nil
  attr :active_section, :atom, required: true

  slot :inner_block, required: true

  def settings(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} current_scope={@current_scope}>
      <div id="settings-cockpit" class="flex flex-col gap-6 lg:flex-row">
        <aside class="shrink-0 lg:w-64">
          <nav
            id="settings-nav"
            class="flex gap-2 overflow-x-auto border-b border-base-300 pb-3 lg:flex-col lg:overflow-visible lg:border-b-0 lg:border-r lg:pb-0 lg:pr-4"
            aria-label="Settings sections"
          >
            <.settings_link
              href={~p"/settings/workspace"}
              icon="hero-building-office-2"
              label="Workspace"
              active={@active_section == :workspace}
            />
            <.settings_link
              href={~p"/settings/connectors"}
              icon="hero-link"
              label="Connectors"
              active={@active_section == :connectors}
            />
            <.settings_link
              href={~p"/settings/users"}
              icon="hero-users"
              label="Users"
              active={@active_section == :users}
            />
          </nav>
        </aside>

        <section class="min-w-0 flex-1">
          {render_slot(@inner_block)}
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :count, :string, default: nil
  attr :current_path, :string, default: nil

  def rail_link(assigns) do
    assigns = assign(assigns, :active, rail_active?(assigns.current_path, assigns.href))

    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex h-10 items-center gap-3 rounded-field px-3 text-small transition group-data-[rail-collapsed=true]/app:justify-center group-data-[rail-collapsed=true]/app:px-0",
        if(@active,
          do:
            "bg-base-100/15 font-semibold text-base-100 shadow-[inset_0_1px_0_rgb(255_255_255/0.08)]",
          else: "font-medium text-base-100/65 hover:bg-base-100/10 hover:text-base-100"
        )
      ]}
      aria-current={if(@active, do: "page", else: nil)}
      title={@label}
    >
      <.icon name={@icon} class="size-5 shrink-0" />
      <span class="min-w-0 flex-1 truncate group-data-[rail-collapsed=true]/app:hidden">
        {@label}
      </span>
      <span
        :if={@count}
        class="rounded-full bg-base-100/15 px-2 py-0.5 text-fine font-semibold text-base-100 group-data-[rail-collapsed=true]/app:hidden"
      >
        {@count}
      </span>
    </.link>
    """
  end

  # A rail entry is active for its own path and anything nested beneath it,
  # so /quotes/42 still lights up "Quotations". Guards against a "/" href
  # matching everything.
  defp rail_active?(nil, _href), do: false

  defp rail_active?(path, href) do
    path == href or String.starts_with?(path, href <> "/")
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  def settings_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex h-10 shrink-0 items-center gap-3 rounded-field px-3 text-small transition",
        if(@active,
          do: "bg-primary/15 font-semibold text-primary",
          else: "font-medium text-base-content/65 hover:bg-base-200 hover:text-base-content"
        )
      ]}
      aria-current={if(@active, do: "page", else: nil)}
    >
      <.icon name={@icon} class="size-5 shrink-0" />
      <span class="truncate">{@label}</span>
    </.link>
    """
  end

  @doc """
  Renders the account cluster (profile, settings, sign out).

  Used in two spots: pinned to the foot of the desktop sidebar rail
  (`placement={:rail}`, opens upward) and as a mobile-only fallback in the
  header (`placement={:header}`, opens downward) since the rail is hidden
  below `lg`. `id_prefix` keeps element ids unique across both instances.
  """
  attr :current_scope, :map, required: true
  attr :placement, :atom, values: [:rail, :header], required: true
  attr :id_prefix, :string, required: true

  def account_menu(assigns) do
    ~H"""
    <details id={"#{@id_prefix}-account-menu"} class="group/account relative">
      <summary
        :if={@placement == :rail}
        id={"#{@id_prefix}-account-trigger"}
        class="flex h-12 cursor-pointer list-none items-center gap-3 rounded-field px-2 text-small text-base-100/75 transition hover:bg-base-100/10 focus:outline-none focus:ring-2 focus:ring-base-100/25 group-data-[rail-collapsed=true]/app:justify-center group-data-[rail-collapsed=true]/app:px-0 [&::-webkit-details-marker]:hidden"
        aria-label="Open account menu"
        title={@current_scope.user.name}
      >
        <span class="grid size-8 shrink-0 place-items-center rounded-full bg-base-100/15 text-micro font-semibold text-base-100/80">
          {user_initials(@current_scope.user)}
        </span>
        <span class="min-w-0 flex-1 text-left group-data-[rail-collapsed=true]/app:hidden">
          <span class="block truncate text-small font-semibold text-base-100">
            {@current_scope.user.name}
          </span>
          <span class="block truncate text-fine text-base-100/55">
            {workspace_name(@current_scope)}
          </span>
        </span>
        <.icon
          name="hero-chevron-up-down"
          class="size-4 shrink-0 text-base-100/45 group-data-[rail-collapsed=true]/app:hidden"
        />
      </summary>

      <summary
        :if={@placement == :header}
        id={"#{@id_prefix}-account-trigger"}
        class="flex h-9 min-w-0 cursor-pointer list-none items-center gap-2 rounded-field bg-base-200 px-2.5 text-small text-base-content/75 transition hover:bg-base-300 hover:text-base-content focus:outline-none focus:ring-2 focus:ring-primary/20 [&::-webkit-details-marker]:hidden"
        aria-label="Open account menu"
        title={@current_scope.user.name}
      >
        <span class="grid size-6 shrink-0 place-items-center rounded-full bg-base-100 text-micro font-semibold text-base-content/70">
          {user_initials(@current_scope.user)}
        </span>
        <span class="hidden max-w-36 truncate font-medium sm:block">
          {@current_scope.user.name}
        </span>
        <.icon
          name="hero-chevron-down"
          class="size-4 text-base-content/45 transition group-open/account:rotate-180"
        />
      </summary>

      <div class={[
        "absolute z-50 w-56 rounded-box border border-base-300 bg-base-100 p-1.5 shadow-moon",
        @placement == :rail && "bottom-full left-0 mb-2",
        @placement == :header && "right-0 mt-2"
      ]}>
        <.link
          navigate={~p"/profile"}
          id={"#{@id_prefix}-profile-link"}
          class="flex h-10 items-center gap-2.5 rounded-field px-2.5 text-small font-medium text-base-content/70 transition hover:bg-base-200 hover:text-base-content focus:outline-none focus:ring-2 focus:ring-primary/20"
        >
          <.icon name="hero-user-circle" class="size-4 text-base-content/55" />
          <span>Profile</span>
        </.link>

        <.link
          :if={Nila.Accounts.Policy.can?(@current_scope, :manage_settings)}
          navigate={~p"/settings/workspace"}
          id={"#{@id_prefix}-settings-link"}
          class="flex h-10 items-center gap-2.5 rounded-field px-2.5 text-small font-medium text-base-content/70 transition hover:bg-base-200 hover:text-base-content focus:outline-none focus:ring-2 focus:ring-primary/20"
        >
          <.icon name="hero-cog-6-tooth" class="size-4 text-base-content/55" />
          <span>Settings</span>
        </.link>

        <div class="my-1.5 border-t border-base-300"></div>

        <.link
          href={~p"/users/log_out"}
          method="delete"
          id={"#{@id_prefix}-sign-out-link"}
          class="flex h-10 items-center gap-2.5 rounded-field px-2.5 text-small font-medium text-base-content/70 transition hover:bg-error/10 hover:text-error focus:outline-none focus:ring-2 focus:ring-error/20"
        >
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
          <span>Sign out</span>
        </.link>
      </div>
    </details>
    """
  end

  defp workspace_name(%{current_org: %{name: name}}) when name not in [nil, ""], do: name
  defp workspace_name(_scope), do: "Personal"

  defp user_initials(%{name: name}) when is_binary(name) do
    name
    |> String.split()
    |> Enum.take(2)
    |> Enum.map_join("", &(String.first(&1) || ""))
    |> String.upcase()
  end

  defp user_initials(_user), do: "U"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
