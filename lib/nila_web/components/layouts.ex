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

  attr :current_path, :string, default: nil, doc: "drives the active sidebar highlight"
  attr :active_client, :map, default: nil, doc: "client that owns the current work surface"
  attr :sales_period, :string, default: nil, doc: "month for sales pages whose URL has no period"

  attr :workbench, :boolean,
    default: false,
    doc: "full-page document review without the navigation rail"

  slot :inner_block, required: true

  slot :bottom_bar, doc: "Content rendered with bottom_bar/1 over the work area"

  def app(%{workbench: true} = assigns) do
    ~H"""
    <main id="app-shell" class="bg-canvas text-base-content h-dvh overflow-hidden">
      {render_slot(@inner_block)}
    </main>
    <.live_component
      :if={@current_scope && (@active_client || @current_scope.current_client)}
      module={NilaWeb.ClientSwitcherComponent}
      id="shell-client-switcher-component"
      current_scope={@current_scope}
      current_path={@current_path}
      active_client={@active_client}
      sales_period={@sales_period}
      show_trigger={false}
    />
    <.keyboard_shortcuts :if={@current_scope} id="workspace-shortcuts" />
    <.flash_group flash={@flash} />
    """
  end

  def app(assigns) do
    assigns =
      assign(
        assigns,
        :sales_home,
        sales_nav_href(
          assigns.current_scope,
          assigns.active_client,
          assigns.current_path,
          assigns.sales_period
        )
      )

    ~H"""
    <div
      id="app-shell"
      class="bg-canvas group/app text-base-content min-h-screen"
      data-rail-collapsed="false"
    >
      <div id="rail-collapse-state" phx-hook="RailCollapse" phx-update="ignore" class="hidden"></div>

      <aside
        id="navigation-rail"
        class="border-rule duration-calm fixed inset-y-0 left-0 z-40 hidden w-64 flex-col border-r px-3 py-4 transition-[width] group-data-[rail-collapsed=true]/app:w-16 lg:flex print:hidden"
      >
        <div class="flex items-center justify-between gap-2 px-1 group-data-[rail-collapsed=true]/app:justify-center group-data-[rail-collapsed=true]/app:gap-0 group-data-[rail-collapsed=true]/app:px-0">
          <.link
            navigate={@sales_home}
            class="flex min-w-0 items-center group-data-[rail-collapsed=true]/app:hidden"
          >
            <.logo class="text-base-content h-5 w-auto" />
          </.link>

          <button
            type="button"
            id="rail-collapse-toggle"
            class="focus-visible:outline-focus hover:bg-interactive hover:text-base-content rounded-field text-ink-muted grid size-8 shrink-0 place-items-center transition focus-visible:outline-2 focus-visible:outline-offset-2"
            aria-label="Toggle navigation"
            data-rail-toggle
          >
            <.icon name="nila-panel-left" class="size-4" />
          </button>
        </div>

        <.live_component
          :if={@current_scope && (@active_client || @current_scope.current_client)}
          module={NilaWeb.ClientSwitcherComponent}
          id="shell-client-switcher-component"
          current_scope={@current_scope}
          current_path={@current_path}
          active_client={@active_client}
          sales_period={@sales_period}
        />
        <nav class="gap-section mt-section flex flex-1 flex-col overflow-y-auto">
          <div class="space-y-1">
            <.rail_link
              href={@sales_home}
              icon="hero-document-text"
              label="Sales & GSTR-1"
              current_path={@current_path}
              active={sales_nav_active?(@current_path)}
            />
            <.rail_link
              href={purchase_nav_href(@sales_home)}
              icon="hero-document-magnifying-glass"
              label="Purchases & ITC"
              current_path={@current_path}
              active={purchase_nav_active?(@current_path)}
            />
            <.rail_link
              href={~p"/banking"}
              icon="hero-building-library"
              label="Banking"
              current_path={@current_path}
            />
          </div>

          <div class="border-rule space-y-1 border-t pt-3">
            <span class="text-ink-muted text-label block px-3 pb-1 font-semibold uppercase group-data-[rail-collapsed=true]/app:hidden">
              Firm
            </span>

            <.rail_link
              href={~p"/app/clients"}
              icon="hero-users"
              label="Clients"
              current_path={@current_path}
            />
            <.rail_link
              href={~p"/app/notices"}
              icon="hero-inbox"
              label="Notices"
              current_path={@current_path}
            />
          </div>
        </nav>

        <div :if={@current_scope} class="border-rule mt-block border-t pt-3">
          <.account_menu current_scope={@current_scope} placement={:rail} id_prefix="layout" />
        </div>
      </aside>

      <div class="lg:duration-calm lg:pl-64 lg:transition-[padding] group-data-[rail-collapsed=true]/app:lg:pl-16">
        <div class="h-screen">
          <div class="bg-quiet text-base-content relative flex h-full flex-col overflow-hidden">
            <%!-- Mobile only: the rail is hidden below lg, so this carries the brand and
                 the account menu. On desktop the rail states the section and the page's
                 own masthead names the object — a strip repeating either is chrome. --%>
            <header class="bg-panel-translucent-surface border-rule z-30 shrink-0 border-b px-4 py-3 backdrop-blur sm:px-6 lg:hidden print:hidden">
              <div class="flex items-center justify-between gap-4">
                <.link navigate={@sales_home} class="flex min-w-0 items-center">
                  <.logo class="text-base-content h-5 w-auto" />
                </.link>

                <div :if={@current_scope} class="flex items-center gap-2">
                  <.account_menu
                    current_scope={@current_scope}
                    placement={:header}
                    id_prefix="mobile"
                  />
                </div>
              </div>
            </header>

            <main class={[
              "flex-1 overflow-y-auto px-4 pt-6 sm:px-6 lg:px-4",
              if(@bottom_bar == [], do: "pb-6", else: "nila-work-area-with-bottom-bar")
            ]}>
              <div class="w-full">
                {render_slot(@inner_block)}
              </div>
            </main>
            {render_slot(@bottom_bar)}
          </div>
        </div>
      </div>
    </div>
    <.keyboard_shortcuts :if={@current_scope} id="workspace-shortcuts" />
    <.flash_group flash={@flash} />
    """
  end

  @doc "Pins actions over the app work area without shifting its scrolling content."
  attr :id, :string, default: nil
  attr :animate, :boolean, default: false
  slot :inner_block, required: true

  def bottom_bar(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "pointer-events-none absolute inset-x-0 bottom-0 z-20 px-4 pb-4 sm:px-6 lg:px-4 print:hidden",
        @animate && "nila-bottom-bar-motion"
      ]}
      phx-remove={
        @animate &&
          Phoenix.LiveView.JS.hide(
            transition:
              {"transition-opacity duration-fast motion-reduce:transition-none", "opacity-100",
               "opacity-0"},
            time: 150,
            blocking: true
          )
      }
    >
      <div class="bg-inverse-surface border-inverse/10 nila-bottom-bar rounded-box shadow-moon text-inverse pointer-events-auto mx-auto max-w-[1480px] border p-3">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :active_section, :atom, required: true

  slot :inner_block, required: true

  def settings(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="settings-cockpit" class="gap-section flex flex-col lg:flex-row">
        <aside class="shrink-0 lg:w-64">
          <nav
            id="settings-nav"
            class="border-rule flex gap-2 overflow-x-auto border-b pb-3 lg:flex-col lg:overflow-visible lg:border-r lg:border-b-0 lg:pr-4 lg:pb-0"
            aria-label="Settings sections"
          >
            <div class="flex gap-2 lg:flex-col">
              <span class="text-ink-subtle text-label hidden px-3 pb-1 font-semibold uppercase lg:block">
                Account
              </span>

              <.settings_link
                href={~p"/settings/profile"}
                icon="hero-user-circle"
                label="Profile"
                active={@active_section == :profile}
              />
              <.settings_link
                href={~p"/settings/security"}
                icon="hero-lock-closed"
                label="Security"
                active={@active_section == :security}
              />
            </div>

            <div
              :if={Nila.Accounts.Policy.can?(@current_scope, :manage_settings)}
              class="lg:mt-block flex gap-2 lg:flex-col"
            >
              <span class="text-ink-subtle text-label hidden px-3 pb-1 font-semibold uppercase lg:block">
                Firm
              </span>

              <.settings_link
                href={~p"/settings/workspace"}
                icon="hero-building-office-2"
                label="Firm"
                active={@active_section == :workspace}
              />
              <.settings_link
                href={~p"/settings/users"}
                icon="hero-users"
                label="Users"
                active={@active_section == :users}
              />
              <.settings_link
                href={~p"/settings/connectors"}
                icon="hero-link"
                label="Connections"
                active={@active_section == :connectors}
              />
            </div>
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
  attr :active, :boolean, default: nil

  def rail_link(assigns) do
    assigns =
      assign(
        assigns,
        :active,
        if(is_boolean(assigns.active),
          do: assigns.active,
          else: rail_active?(assigns.current_path, assigns.href)
        )
      )

    ~H"""
    <.link
      navigate={@href}
      class={[
        "rounded-field text-ui flex h-10 items-center gap-3 px-3 transition group-data-[rail-collapsed=true]/app:justify-center group-data-[rail-collapsed=true]/app:px-0",
        if(@active,
          do: "bg-interactive ring-rule text-base-content font-semibold ring-1 ring-inset",
          else: "hover:bg-interactive hover:text-base-content text-ink-muted font-medium"
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
        class="bg-interactive text-base-content text-ui rounded-full px-2 py-0.5 font-semibold group-data-[rail-collapsed=true]/app:hidden"
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

  defp rail_active?(request_target, href) do
    path = URI.parse(request_target).path
    path == href or String.starts_with?(path, href <> "/")
  end

  defp sales_nav_href(current_scope, active_client, current_path, sales_period) do
    case active_client || (current_scope && current_scope.current_client) do
      %{id: client_id} ->
        period =
          sales_period || sales_nav_period(current_path) ||
            Nila.Gst.Filing.Calendar.closeable_period(Date.utc_today())

        ~p"/app/gst/#{client_id}/#{period}/sales"

      _none ->
        ~p"/app/clients"
    end
  end

  defp sales_nav_period(path) when is_binary(path) do
    uri = URI.parse(path)

    case Regex.run(~r"^/gst/\d+/(\d{4}-\d{2})(?:/|$)", uri.path) do
      [_, period] -> period
      _ -> if uri.path == "/gst/upload", do: URI.decode_query(uri.query || "")["period"]
    end
  end

  defp sales_nav_period(_), do: nil

  defp purchase_nav_href(sales_home),
    do: String.replace_suffix(sales_home, "/sales", "/purchases")

  defp purchase_nav_active?(nil), do: false

  defp purchase_nav_active?(path),
    do: Regex.match?(~r"^/gst/\d+/\d{4}-\d{2}/purchases(?:/|$)", URI.parse(path).path)

  defp sales_nav_active?(nil), do: false

  defp sales_nav_active?(request_target) do
    path = URI.parse(request_target).path

    String.starts_with?(path, "/sales-bills/") or
      Regex.match?(~r"^/gst/\d+/\d{4}-\d{2}/(?:sales(?:/.*)?|review/sales)$", path)
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
        "nila-settings-link rounded-field text-ui flex h-10 shrink-0 items-center gap-3 px-3 transition",
        if(@active,
          do: "font-semibold",
          else: "hover:bg-interactive hover:text-ink text-ink-subtle font-medium"
        )
      ]}
      data-state={if(@active, do: "active", else: "inactive")}
      aria-current={if(@active, do: "page", else: nil)}
    >
      <.icon name={@icon} class="size-5 shrink-0" /> <span class="truncate">{@label}</span>
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
    <div id={"#{@id_prefix}-account-menu"} class="nila-account-menu relative">
      <button
        :if={@placement == :rail}
        type="button"
        id={"#{@id_prefix}-account-trigger"}
        popovertarget={"#{@id_prefix}-account-popover"}
        class="focus:ring-focus hover:bg-interactive rounded-field text-ink-muted text-ui flex h-12 w-full cursor-pointer items-center gap-3 px-2 transition group-data-[rail-collapsed=true]/app:justify-center group-data-[rail-collapsed=true]/app:px-0 focus:ring-2 focus:outline-none"
        aria-label="Open account menu"
        title={@current_scope.user.name}
      >
        <span class="bg-interactive text-base-content text-label grid size-8 shrink-0 place-items-center rounded-full font-semibold">
          {user_initials(@current_scope.user)}
        </span>

        <span class="min-w-0 flex-1 text-left group-data-[rail-collapsed=true]/app:hidden">
          <span class="text-base-content text-ui block truncate font-semibold">
            {@current_scope.user.name}
          </span>

          <span class="block truncate">
            <.context_text tone="muted">{workspace_name(@current_scope)}</.context_text>
          </span>
        </span>

        <.icon
          name="hero-chevron-up-down"
          class="text-ink-subtle size-4 shrink-0 group-data-[rail-collapsed=true]/app:hidden"
        />
      </button>

      <button
        :if={@placement == :header}
        type="button"
        id={"#{@id_prefix}-account-trigger"}
        popovertarget={"#{@id_prefix}-account-popover"}
        class="bg-quiet hover:bg-interactive hover:text-ink nila-account-trigger rounded-field text-ink-muted text-ui flex h-9 min-w-0 cursor-pointer items-center gap-2 px-3 transition"
        aria-label="Open account menu"
        title={@current_scope.user.name}
      >
        <span class="bg-panel-surface text-ink-muted text-label grid size-6 shrink-0 place-items-center rounded-full font-semibold">
          {user_initials(@current_scope.user)}
        </span>

        <span class="hidden max-w-36 truncate font-medium sm:block">
          {@current_scope.user.name}
        </span>

        <.icon
          name="hero-chevron-down"
          class="nila-account-menu-chevron text-ink-faint size-4 transition"
        />
      </button>

      <div
        id={"#{@id_prefix}-account-popover"}
        popover="auto"
        data-placement={@placement}
        class="nila-menu"
        aria-label="Account actions"
      >
        <button
          type="button"
          id={"#{@id_prefix}-shortcuts-link"}
          class="nila-menu-item"
          phx-click={JS.dispatch("nila:show-shortcuts", to: "#workspace-shortcuts")}
        >
          <.icon name="hero-command-line" class="text-ink-subtle size-4" />
          <span>Keyboard shortcuts</span>
        </button>

        <.link
          navigate={~p"/settings/profile"}
          id={"#{@id_prefix}-settings-link"}
          class="nila-menu-item"
        >
          <.icon name="hero-cog-6-tooth" class="text-ink-subtle size-4" /> <span>Settings</span>
        </.link>

        <div class="border-rule my-1.5 border-t"></div>

        <.link
          href={~p"/users/log_out"}
          method="delete"
          id={"#{@id_prefix}-sign-out-link"}
          class="nila-menu-item"
          data-tone="error"
        >
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> <span>Sign out</span>
        </.link>
      </div>
    </div>
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
    <div id={@id} class="nila-flash-group" aria-live="polite">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
      <.flash
        id="connection-error"
        kind={:error}
        title="Connection lost"
        phx-disconnected={show("#connection-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#connection-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting… <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
