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
    plug NilaWeb.WorkspaceNavigation, :remember_path
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

  pipeline :firm_browser do
    plug :require_firm_user
  end

  pipeline :require_workspace_management do
    plug :require_capability, :manage_connectors
  end

  pipeline :require_export do
    plug :require_capability, :export
  end

  pipeline :require_sign_off do
    plug :require_capability, :sign_off
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :workspace_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  scope "/api/workspace", NilaWeb do
    pipe_through :workspace_api
    get "/navigation", WorkspaceNavigationController, :show
    put "/navigation", WorkspaceNavigationController, :update
    get "/notices", NoticesWorkspaceController, :index
    get "/notices/:id", NoticesWorkspaceController, :show
    post "/notices/check", NoticesWorkspaceController, :check_all
    post "/notices/retry", NoticesWorkspaceController, :retry
    post "/notices/clients/:client_id/check", NoticesWorkspaceController, :check
    post "/notices/clients/:client_id/otp", NoticesWorkspaceController, :otp
    post "/notices/clients/:client_id/verify", NoticesWorkspaceController, :verify
    get "/settings", SettingsWorkspaceController, :show
    patch "/settings/name", SettingsWorkspaceController, :name
    post "/settings/email", SettingsWorkspaceController, :email
    post "/settings/password", SettingsWorkspaceController, :password
    post "/settings/sessions", SettingsWorkspaceController, :sessions
    patch "/settings/firm", SettingsWorkspaceController, :firm
    post "/settings/invitations", SettingsWorkspaceController, :invite
    patch "/settings/members/:id", SettingsWorkspaceController, :member
    get "/clients", ClientsWorkspaceController, :index
    post "/clients", ClientsWorkspaceController, :create
    post "/clients/import/preview", ClientsWorkspaceController, :preview_import
    post "/clients/import", ClientsWorkspaceController, :import_clients
    get "/clients/:id", ClientsWorkspaceController, :show
    patch "/clients/:id", ClientsWorkspaceController, :update
    get "/clients/:client_id/gst-connection", GstConnectionController, :show
    post "/clients/:client_id/gst-connection/otp", GstConnectionController, :otp
    post "/clients/:client_id/gst-connection/verify", GstConnectionController, :verify
    post "/clients/:client_id/business-invitation", BusinessInvitationController, :create
    get "/sales/:client_id/:period", SalesWorkspaceController, :show
    get "/purchases/:client_id/:period", PurchaseWorkspaceController, :show
    get "/purchases/:client_id/:period/gstr2b", Gstr2bWorkspaceController, :show
    post "/purchases/:client_id/:period/gstr2b/fetch", Gstr2bWorkspaceController, :fetch
    post "/purchases/:client_id/:period/gstr2b/otp", Gstr2bWorkspaceController, :otp
    post "/purchases/:client_id/:period/gstr2b/verify", Gstr2bWorkspaceController, :verify

    post "/purchases/:client_id/:period/gstr2b/import",
         Gstr2bWorkspaceController,
         :import_statement

    get "/purchases/:client_id/:period/review", PurchaseReviewController, :show
    get "/purchases/:client_id/:period/review/:item_id", PurchaseReviewController, :show
    post "/purchases/:client_id/:period/review/:item_id/source", PurchaseReviewController, :source

    post "/purchases/:client_id/:period/review/:item_id/treatment",
         PurchaseReviewController,
         :treatment

    post "/purchases/:client_id/:period/review/:item_id/document",
         PurchaseReviewController,
         :document

    post "/purchases/:client_id/:period/review/treatment", PurchaseReviewController, :treatment

    post "/purchases/:client_id/:period/review/bulk-treatment",
         PurchaseReviewController,
         :bulk_treatment

    post "/purchases/:client_id/:period/review/document", PurchaseReviewController, :document
    get "/sales/:client_id/:period/checks", SalesMonthChecksController, :show
    post "/sales/:client_id/:period/checks/decision", SalesMonthChecksController, :decision
    get "/sales/:client_id/:period/invoices/:invoice_id", SalesReviewController, :show
    patch "/sales/:client_id/:period/invoices/:invoice_id", SalesReviewController, :update
    post "/sales/:client_id/:period/invoices/:invoice_id/confirm", SalesReviewController, :confirm
    get "/sales/:client_id/:period/uploads", SalesUploadController, :index
    post "/sales/:client_id/:period/uploads/prepare", SalesUploadController, :prepare
    post "/sales/:client_id/:period/uploads", SalesUploadController, :create
  end

  scope "/app", NilaWeb do
    pipe_through [:browser, :authenticated_browser, :verified_browser, :firm_browser]
    get "/notices", ReactAppController, :index
    get "/notices/:id", ReactAppController, :index
    get "/settings", ReactAppController, :index
    get "/settings/profile", ReactAppController, :index
    get "/settings/security", ReactAppController, :index
    get "/settings/workspace", ReactAppController, :index
    get "/settings/users", ReactAppController, :index
    get "/", ReactAppController, :home
    get "/clients", ReactAppController, :index
    get "/clients/new", ReactAppController, :index
    get "/clients/import", ReactAppController, :index
    get "/clients/:client_id/edit", ReactAppController, :index
    get "/gst/:client_id/:period/sales", ReactAppController, :index
    get "/gst/:client_id/:period/sales/register", ReactAppController, :index
    get "/gst/:client_id/:period/sales/checks", ReactAppController, :index
    get "/gst/:client_id/:period/sales/sections/:section", ReactAppController, :index
    get "/gst/:client_id/:period/sales/invoices/:invoiceId", ReactAppController, :index
    get "/gst/:client_id/:period/sales/upload", ReactAppController, :index
    get "/gst/:client_id/:period/sales/uploads", ReactAppController, :index
    get "/gst/:client_id/:period/purchases", ReactAppController, :index
    get "/gst/:client_id/:period/purchases/register", ReactAppController, :index
    get "/gst/:client_id/:period/purchases/review", ReactAppController, :index
    get "/gst/:client_id/:period/purchases/review/:itemId", ReactAppController, :index
  end

  pipeline :business_api do
    plug :accepts, ["json", "pdf"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  scope "/api/business", NilaWeb do
    pipe_through :business_api
    get "/", BusinessController, :bootstrap
    get "/bootstrap", BusinessController, :bootstrap
    patch "/profile", BusinessController, :profile
    get "/services", BusinessController, :services
    post "/services", BusinessController, :create_service
    patch "/services/:id", BusinessController, :update_service
    delete "/services/:id", BusinessController, :delete_service
    post "/customers", BusinessController, :create_customer
    patch "/customers/:id", BusinessController, :update_customer
    post "/invoices", BusinessController, :create_invoice
    post "/invoices/preview", BusinessController, :preview
    post "/invoices/calculate", BusinessController, :calculate
    get "/invoices/:id", BusinessController, :show_invoice
    patch "/invoices/:id", BusinessController, :update_invoice
    post "/invoices/:id/issue", BusinessController, :issue_invoice
    post "/invoices/:id/quotation-status", BusinessController, :quotation_status
    post "/invoices/:id/convert", BusinessController, :convert_quotation
    get "/invoices/:id/pdf", BusinessController, :pdf
  end

  scope "/app/business", NilaWeb do
    pipe_through [:browser, :authenticated_browser, :verified_browser]
    get "/", ReactAppController, :index
    get "/invoices", ReactAppController, :index
    get "/invoices/new", ReactAppController, :index
    get "/invoices/:invoice_id", ReactAppController, :index
    get "/quotations", ReactAppController, :index
    get "/quotations/new", ReactAppController, :index
    get "/quotations/:invoice_id", ReactAppController, :index
    get "/customers", ReactAppController, :index
    get "/services", ReactAppController, :index
    get "/settings", ReactAppController, :index
  end

  pipeline :webhook do
    plug :accepts, ["json"]
  end

  pipeline :local_upload do
    plug :accepts, ["json", "html"]
  end

  # Dev and test have no bucket to presign a PUT against, so the app plays the
  # part. In prod the browser uploads straight to R2 and this route is absent.
  if Mix.env() != :prod do
    scope "/uploads", NilaWeb do
      pipe_through :local_upload

      put "/local", LocalUploadController, :update
    end
  end

  # Health probe — used by the container healthcheck and uptime monitors.
  # Excluded from force_ssl (see config/prod.exs) so the in-container HTTP
  # check isn't redirected to https.
  scope "/", NilaWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end

  scope "/api/tally", NilaWeb do
    pipe_through :api

    post "/pairings", TallyPairingController, :create
    post "/pairings/exchange", TallyPairingController, :exchange
    delete "/device", TallyPairingController, :revoke
    post "/syncs", TallySyncController, :create
    put "/syncs/:id/masters", TallySyncController, :masters
    put "/syncs/:id/vouchers", TallySyncController, :vouchers
    post "/syncs/:id/fail", TallySyncController, :fail
  end

  # Public legal & contact pages — reachable by everyone, logged in or out.
  scope "/", NilaWeb do
    pipe_through :browser

    get "/privacy", PageController, :privacy
    get "/terms", PageController, :terms
    get "/data-deletion", PageController, :data_deletion
    get "/contact", PageController, :contact
    post "/contact/callback", PageController, :request_callback
  end

  # Public marketing site — served to logged-out visitors.
  scope "/", NilaWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    get "/", PageController, :home
    get "/users/sign_up", PageController, :signup_redirect

    get "/users/log_in", AuthPageController, :login
    get "/users/reset_password", AuthPageController, :forgot
    post "/users/reset_password", AuthPageController, :forgot_submit
    get "/users/reset_password/:token", AuthPageController, :reset
    post "/users/reset_password/:token", AuthPageController, :reset_submit
  end

  scope "/", NilaWeb do
    pipe_through :browser

    post "/users/log_in", UserSessionController, :create
    delete "/users/log_out", UserSessionController, :delete
    get "/users/confirm/:token", UserConfirmationController, :confirm
    post "/users/invite/:token", UserInviteController, :create

    get "/users/invite/:token", AuthPageController, :invite
  end

  scope "/", NilaWeb do
    pipe_through [:browser, :authenticated_browser]

    get "/users/confirm", AuthPageController, :confirmation
    post "/users/confirm", AuthPageController, :resend
  end

  scope "/", NilaWeb do
    pipe_through [:browser, :authenticated_browser, :verified_browser, :firm_browser]

    get "/clients", LegacyWorkspaceController, :show
    get "/clients/new", LegacyWorkspaceController, :show
    get "/clients/:id/edit", LegacyWorkspaceController, :show
    get "/notices", LegacyWorkspaceController, :show
    get "/notices/:id", LegacyWorkspaceController, :show
    get "/settings/profile", LegacyWorkspaceController, :show
    get "/settings/security", LegacyWorkspaceController, :show
    get "/settings/workspace", LegacyWorkspaceController, :show
    get "/settings/users", LegacyWorkspaceController, :show
    get "/gst/:client_id/:period/purchases", LegacyWorkspaceController, :show

    get "/gst/:client_id/:period/purchases/register",
        LegacyWorkspaceController,
        :purchase_register

    get "/gst/2b", LegacyWorkspaceController, :gstr2b

    get "/gst/:client_id/:period/purchases/invoices/:item_id",
        LegacyWorkspaceController,
        :purchase_review

    live_session :require_verified,
      on_mount: [
        {NilaWeb.UserAuth, :require_verified},
        {NilaWeb.UserAuth, :require_firm},
        {NilaWeb.UserAuth, :mount_current_path}
      ] do
      live "/today", TodayLive, :index
      live "/sales-bills/:client_id/batch/:batch_ref", Gst.SalesBillsLive, :show
      live "/register", Gst.RegisterLive, :index
      live "/banking", Banking.UploadLive, :index
      live "/banking/new", Banking.UploadLive, :new
      live "/banking/:id", Banking.StatementLive, :show
      live "/gst/upload", Gst.UploadLive, :new
      live "/gst/:client_id/:period/import-excel", Gst.ExcelImportLive, :new
      live "/gst/:client_id/:period/purchases/uploads", Gst.PurchaseUploadsLive, :index
      live "/gst/:client_id/:period/purchases/import-excel", Gst.PurchaseExcelImportLive, :new

      live "/gst/:client_id/:period", Gst.MonthLive, :index
      live "/gst/:client_id/:period/gstr3b", Gst.MonthLive, :gstr3b

      live "/gst/:client_id/:period/sales", Gst.MonthLive, :sales_workspace
      live "/gst/:client_id/:period/sales/invoices/:source_id", Gst.InvoiceReviewLive, :show
      live "/gst/:client_id/:period/sales/:view", Gst.MonthLive, :sales_workspace
      live "/gst/:client_id/:period/review/:lane", Gst.MonthLive, :review

      # Settings share the product LiveView session so moving between work and
      # setup does not reload the shell. Firm-only pages enforce their own
      # capability guard in the LiveView.
      live "/settings/connectors", Settings.ConnectorsLive, :index
      live "/settings/connectors/tally/pair/:approval_code", Settings.TallyPairingLive, :show
    end

    # Tenant-scoped GST evidence: the controller checks the current org owns the
    # client_month before streaming, so bills never leak across firms.
    get "/gst/:client_id/:period/evidence/:basename", GstEvidenceController, :show
    get "/gst/sales-template.xlsx", SalesExcelController, :template
    get "/gst/purchases-template.xlsx", PurchaseExcelController, :template
    get "/gst/:client_id/:period/purchases/workings.xlsx", PurchaseWorkingsController, :download
    get "/gst/:client_id/:period/original/:dump_id/:index", GstEvidenceController, :original

    get "/sales-bills/:client_id/dumps/:dump_id/evidence/:basename",
        GstEvidenceController,
        :sales_bill

    get "/gstr1/:client_id/:period/return.json", Gstr1Controller, :return_json
    get "/gstr1/:client_id/:period/workings.xlsx", Gstr1Controller, :workings_xlsx
    get "/gstr1/:client_id/:period/winman-b2b.xlsm", Gstr1Controller, :winman_b2b
    get "/gstr1/:client_id/:period/evidence/:basename", Gstr1Controller, :evidence

    get "/settings/profile/confirm_email/:token", AuthPageController, :confirm_email
    get "/settings", SettingsController, :index
    get "/clients/import-template.xlsx", ClientImportController, :template
    get "/notices/:id/documents/:index", NoticeDocumentController, :show
    get "/gst/2b/statements/:id/download", Gstr2bController, :download
    post "/clients/:id/select", ClientContextController, :update
    post "/settings/security/password", UserSettingsController, :update_password
    post "/settings/security/sessions", UserSettingsController, :delete_sessions
  end

  scope "/gstr1", NilaWeb do
    pipe_through [
      :browser,
      :authenticated_browser,
      :verified_browser,
      :require_export
    ]

    get "/:client_id/:period/tally.xml", Gstr1Controller, :tally_download
  end

  scope "/sales-bills", NilaWeb do
    pipe_through [
      :browser,
      :authenticated_browser,
      :verified_browser,
      :require_export
    ]

    get "/:client_id/batch/:batch_ref/tally.xml", Gstr1Controller, :sales_bills_tally_download

    get "/:client_id/batch/:batch_ref/gstr1.json",
        Gstr1Controller,
        :sales_bills_gstr1_download
  end

  scope "/gstr1", NilaWeb do
    pipe_through [
      :browser,
      :authenticated_browser,
      :verified_browser,
      :require_export
    ]

    post "/:client_id/:period/tally", Gstr1Controller, :tally_export
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
    post "/resend", ResendController, :ingest
  end

  # Enable operational and design references in development
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
      live "/design-system", NilaWeb.Dev.DesignSystemLive

      # The error pages, previewable — `debug_errors: true` means a real 404 in
      # dev renders the Plug debugger instead of ours.
      get "/errors/:status", NilaWeb.ErrorPreviewController, :show
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

  defp require_firm_user(conn, opts),
    do: NilaWeb.UserAuth.require_firm_user(conn, opts)

  defp require_capability(conn, capability),
    do: NilaWeb.UserAuth.require_capability(conn, capability)
end
