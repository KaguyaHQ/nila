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
      class="group/app moonlight-night text-base-100/90 min-h-screen"
      data-rail-collapsed="false"
    >
      <div id="rail-collapse-state" phx-hook="RailCollapse" phx-update="ignore" class="hidden"></div>

      <aside class="fixed inset-y-0 left-0 z-40 hidden w-64 flex-col px-3 py-4 transition-[width] duration-200 group-data-[rail-collapsed=true]/app:w-16 lg:flex print:hidden">
        <div class="flex items-center justify-between gap-2 px-1 group-data-[rail-collapsed=true]/app:justify-center group-data-[rail-collapsed=true]/app:gap-0 group-data-[rail-collapsed=true]/app:px-0">
          <.link
            navigate={~p"/today"}
            class="flex min-w-0 items-center group-data-[rail-collapsed=true]/app:hidden"
          >
            <.logo class="text-base-100 h-5 w-auto" />
          </.link>

          <button
            type="button"
            id="rail-collapse-toggle"
            class="focus-visible:outline-base-100/40 hover:bg-base-100/10 hover:text-base-100 rounded-field text-base-100/55 grid size-8 shrink-0 place-items-center transition focus-visible:outline-2 focus-visible:outline-offset-2"
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
              href={~p"/gst/upload"}
              icon="hero-arrow-up-tray"
              label="Bring in documents"
              current_path={@current_path}
            />
            <.rail_link
              href={~p"/clients"}
              icon="hero-users"
              label="Clients"
              current_path={@current_path}
            />
          </div>
        </nav>

        <div :if={@current_scope} class="border-base-100/10 mt-4 border-t pt-3">
          <.account_menu current_scope={@current_scope} placement={:rail} id_prefix="layout" />
        </div>
      </aside>

      <div class="lg:pl-64 lg:transition-[padding] lg:duration-200 group-data-[rail-collapsed=true]/app:lg:pl-16">
        <div class="h-screen lg:p-3">
          <div class="bg-base-200 lg:rounded-box lg:shadow-moon-lg text-base-content flex h-full flex-col overflow-hidden lg:ring-1 lg:ring-white/40">
            <header class="bg-base-100/80 border-base-300 z-30 shrink-0 border-b px-4 py-2.5 backdrop-blur sm:px-6 lg:px-8 print:hidden">
              <div class="flex items-center justify-between gap-4">
                <nav
                  aria-label="Breadcrumb"
                  class="text-base-content/60 text-small flex min-w-0 items-center gap-1.5"
                >
                  <span class="text-base-content/75 font-medium">Nila</span>
                  <span :if={@page_title} class="text-base-content/30">/</span>
                  <span :if={@page_title} class="text-base-content truncate font-medium">
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
            class="border-base-300 flex gap-2 overflow-x-auto border-b pb-3 lg:flex-col lg:overflow-visible lg:border-r lg:border-b-0 lg:pr-4 lg:pb-0"
            aria-label="Settings sections"
          >
            <.settings_link
              href={~p"/settings/workspace"}
              icon="hero-building-office-2"
              label="Firm"
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
        "rounded-field text-small flex h-10 items-center gap-3 px-3 transition group-data-[rail-collapsed=true]/app:justify-center group-data-[rail-collapsed=true]/app:px-0",
        if(@active,
          do:
            "bg-base-100/15 text-base-100 font-semibold shadow-[inset_0_1px_0_rgb(255_255_255/0.08)]",
          else: "hover:bg-base-100/10 hover:text-base-100 text-base-100/65 font-medium"
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
        class="bg-base-100/15 text-base-100 text-fine rounded-full px-2 py-0.5 font-semibold group-data-[rail-collapsed=true]/app:hidden"
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
        "rounded-field text-small flex h-10 shrink-0 items-center gap-3 px-3 transition",
        if(@active,
          do: "bg-primary/15 text-primary font-semibold",
          else: "hover:bg-base-200 hover:text-base-content text-base-content/65 font-medium"
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
        class="focus:ring-base-100/25 hover:bg-base-100/10 rounded-field text-base-100/75 text-small flex h-12 cursor-pointer list-none items-center gap-3 px-2 transition group-data-[rail-collapsed=true]/app:justify-center group-data-[rail-collapsed=true]/app:px-0 focus:ring-2 focus:outline-none [&::-webkit-details-marker]:hidden"
        aria-label="Open account menu"
        title={@current_scope.user.name}
      >
        <span class="bg-base-100/15 text-base-100/80 text-micro grid size-8 shrink-0 place-items-center rounded-full font-semibold">
          {user_initials(@current_scope.user)}
        </span>
        <span class="min-w-0 flex-1 text-left group-data-[rail-collapsed=true]/app:hidden">
          <span class="text-base-100 text-small block truncate font-semibold">
            {@current_scope.user.name}
          </span>
          <span class="text-base-100/55 text-fine block truncate">
            {workspace_name(@current_scope)}
          </span>
        </span>
        <.icon
          name="hero-chevron-up-down"
          class="text-base-100/45 size-4 shrink-0 group-data-[rail-collapsed=true]/app:hidden"
        />
      </summary>

      <summary
        :if={@placement == :header}
        id={"#{@id_prefix}-account-trigger"}
        class="bg-base-200 focus:ring-primary/20 hover:bg-base-300 hover:text-base-content rounded-field text-base-content/75 text-small flex h-9 min-w-0 cursor-pointer list-none items-center gap-2 px-2.5 transition focus:ring-2 focus:outline-none [&::-webkit-details-marker]:hidden"
        aria-label="Open account menu"
        title={@current_scope.user.name}
      >
        <span class="bg-base-100 text-base-content/70 text-micro grid size-6 shrink-0 place-items-center rounded-full font-semibold">
          {user_initials(@current_scope.user)}
        </span>
        <span class="hidden max-w-36 truncate font-medium sm:block">
          {@current_scope.user.name}
        </span>
        <.icon
          name="hero-chevron-down"
          class="text-base-content/45 size-4 transition group-open/account:rotate-180"
        />
      </summary>

      <div class={[
        "bg-base-100 border-base-300 rounded-box shadow-moon absolute z-50 w-56 border p-1.5",
        @placement == :rail && "bottom-full left-0 mb-2",
        @placement == :header && "right-0 mt-2"
      ]}>
        <.link
          navigate={~p"/profile"}
          id={"#{@id_prefix}-profile-link"}
          class="focus:ring-primary/20 hover:bg-base-200 hover:text-base-content rounded-field text-base-content/70 text-small flex h-10 items-center gap-2.5 px-2.5 font-medium transition focus:ring-2 focus:outline-none"
        >
          <.icon name="hero-user-circle" class="text-base-content/55 size-4" />
          <span>Profile</span>
        </.link>

        <.link
          :if={Nila.Accounts.Policy.can?(@current_scope, :manage_settings)}
          navigate={~p"/settings/workspace"}
          id={"#{@id_prefix}-settings-link"}
          class="focus:ring-primary/20 hover:bg-base-200 hover:text-base-content rounded-field text-base-content/70 text-small flex h-10 items-center gap-2.5 px-2.5 font-medium transition focus:ring-2 focus:outline-none"
        >
          <.icon name="hero-cog-6-tooth" class="text-base-content/55 size-4" />
          <span>Settings</span>
        </.link>

        <div class="border-base-300 my-1.5 border-t"></div>

        <.link
          href={~p"/users/log_out"}
          method="delete"
          id={"#{@id_prefix}-sign-out-link"}
          class="focus:ring-error/20 hover:bg-error/10 hover:text-error rounded-field text-base-content/70 text-small flex h-10 items-center gap-2.5 px-2.5 font-medium transition focus:ring-2 focus:outline-none"
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
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
