defmodule NilaWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use NilaWeb, :controller
      use NilaWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico favicon.svg robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      alias NilaWeb.UserAuth

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import NilaWeb.Components.Button
      import NilaWeb.Components.Input
      import NilaWeb.Components.Modal
      import NilaWeb.Components.Flash
      import NilaWeb.Components.Icon
      import NilaWeb.Components.Logo
      import NilaWeb.Components.Badge
      import NilaWeb.Components.Card
      import NilaWeb.Components.Fold
      import NilaWeb.Components.Typography
      import NilaWeb.Components.Table
      import NilaWeb.Components.Menu
      import NilaWeb.Components.Page
      import NilaWeb.Components.Form
      import NilaWeb.Components.Feedback
      import NilaWeb.Components.ChaseHistory
      import NilaWeb.Components.Evidence
      import NilaWeb.Components.SelectableList
      import NilaWeb.Components.LedgerPicker

      import Nila.Formatters,
        only: [
          format_display_date: 1,
          format_display_datetime: 1,
          format_long_display_date: 1,
          format_money: 1,
          format_money: 2,
          format_time: 1,
          humanize_label: 1,
          human_status: 1,
          issue_label: 1,
          month_state_label: 1,
          period_label: 1
        ]

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias NilaWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: NilaWeb.Endpoint,
        router: NilaWeb.Router,
        statics: NilaWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
