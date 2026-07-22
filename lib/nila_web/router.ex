defmodule NilaWeb.Router do
  use NilaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NilaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :redirect_if_authenticated do
    plug :redirect_if_user_is_authenticated
  end

  pipeline :authenticated_browser do
    plug :require_authenticated_user
  end

  pipeline :verified_browser do
    plug :require_verified_user
  end

  pipeline :require_workspace_management do
    plug :require_capability, :manage_connectors
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :webhook do
    plug :accepts, ["json"]
  end

  # Health probe — used by the container healthcheck and uptime monitors.
  # Excluded from force_ssl (see config/prod.exs) so the in-container HTTP
  # check isn't redirected to https.
  scope "/", NilaWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end

  # Public legal & contact pages — reachable by everyone, logged in or out.
  scope "/", NilaWeb do
    pipe_through :browser

    get "/privacy", PageController, :privacy
    get "/terms", PageController, :terms
    get "/contact", PageController, :contact
  end

  # Public marketing site — served to logged-out visitors.
  scope "/", NilaWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    get "/", PageController, :home
    post "/users/sign_up", UserRegistrationController, :create

    live_session :redirect_if_authenticated,
      on_mount: [{NilaWeb.UserAuth, :redirect_if_authenticated}] do
      live "/users/sign_up", UserRegistrationLive, :new
      live "/users/log_in", UserLoginLive, :new
      live "/users/reset_password", UserForgotPasswordLive, :new
      live "/users/reset_password/:token", UserResetPasswordLive, :edit
    end
  end

  scope "/", NilaWeb do
    pipe_through :browser

    post "/users/log_in", UserSessionController, :create
    delete "/users/log_out", UserSessionController, :delete
    get "/users/confirm/:token", UserConfirmationController, :confirm
    post "/users/invite/:token", UserInviteController, :create

    live_session :accept_invite,
      on_mount: [{NilaWeb.UserAuth, :mount_current_scope}] do
      live "/users/invite/:token", UserInviteLive, :new
    end
  end

  scope "/", NilaWeb do
    pipe_through [:browser, :authenticated_browser]

    live_session :require_authenticated,
      on_mount: [{NilaWeb.UserAuth, :require_authenticated}] do
      live "/users/confirm", UserConfirmationLive, :new
    end
  end

  scope "/", NilaWeb do
    pipe_through [:browser, :authenticated_browser, :verified_browser]

    live_session :require_verified,
      on_mount: [
        {NilaWeb.UserAuth, :require_verified},
        {NilaWeb.UserAuth, :mount_current_path}
      ] do
      live "/today", TodayLive, :index
      live "/clients", ClientsLive, :index
      live "/register", Gst.RegisterLive, :index
      live "/clients/new", ClientNewLive, :new
      live "/clients/:id/edit", ClientEditLive, :edit
      live "/gst/upload", Gst.UploadLive, :new
      live "/gst/:client_id/:period", Gst.MonthLive, :index
      live "/gst/:client_id/:period/exceptions", Gst.ExceptionsLive, :index
      live "/settings/profile", Settings.ProfileLive, :edit
      live "/settings/profile/confirm_email/:token", Settings.ProfileLive, :confirm_email
      live "/settings/security", Settings.SecurityLive, :edit
    end

    # Tenant-scoped GST evidence: the controller checks the current org owns the
    # client_month before streaming, so bills never leak across firms.
    get "/gst/:client_id/:period/evidence/:basename", GstEvidenceController, :show
    get "/gst/:client_id/:period/original/:dump_id/:index", GstEvidenceController, :original
    get "/gstr1/:client_id/:period/return.json", Gstr1Controller, :return_json
    get "/gstr1/:client_id/:period/evidence/:basename", Gstr1Controller, :evidence

    get "/settings", SettingsController, :index
    post "/settings/security/password", UserSettingsController, :update_password
    post "/settings/security/sessions", UserSettingsController, :delete_sessions

    # Firm settings (workspace, connectors, users) are owner / admin only. The capability guard mounts the scope and redirects everyone
    # else back to their cockpit.
    live_session :settings,
      on_mount: [
        {NilaWeb.UserAuth, {:require, :manage_settings}},
        {NilaWeb.UserAuth, :mount_current_path}
      ] do
      live "/settings/workspace", Settings.WorkspaceLive, :index
      live "/settings/connectors", Settings.ConnectorsLive, :index
      live "/settings/users", Settings.UsersLive, :index
    end
  end

  # Connecting / disconnecting inboxes is a workspace-management action.
  scope "/integrations", NilaWeb do
    pipe_through [
      :browser,
      :authenticated_browser,
      :verified_browser,
      :require_workspace_management
    ]

    get "/:provider/connect", IntegrationsController, :connect
    get "/:provider/callback", IntegrationsController, :callback
  end

  scope "/webhooks", NilaWeb.Webhooks do
    pipe_through :webhook

    get "/whatsapp", WhatsAppController, :verify
    post "/whatsapp", WhatsAppController, :ingest
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:nila, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: NilaWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  defp fetch_current_scope_for_user(conn, opts),
    do: NilaWeb.UserAuth.fetch_current_scope_for_user(conn, opts)

  defp redirect_if_user_is_authenticated(conn, opts),
    do: NilaWeb.UserAuth.redirect_if_user_is_authenticated(conn, opts)

  defp require_authenticated_user(conn, opts),
    do: NilaWeb.UserAuth.require_authenticated_user(conn, opts)

  defp require_verified_user(conn, opts),
    do: NilaWeb.UserAuth.require_verified_user(conn, opts)

  defp require_capability(conn, capability),
    do: NilaWeb.UserAuth.require_capability(conn, capability)
end
