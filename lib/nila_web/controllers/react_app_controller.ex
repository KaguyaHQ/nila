defmodule NilaWeb.ReactAppController do
  use NilaWeb, :controller

  def home(conn, _params) do
    {conn, path} = NilaWeb.WorkspaceNavigation.home(conn, conn.assigns.current_scope)
    redirect(conn, to: path)
  end

  def index(conn, _params) do
    case app_html() do
      {:ok, html} ->
        csrf = Plug.CSRFProtection.get_csrf_token()

        html =
          String.replace(html, "</head>", ~s(<meta name="csrf-token" content="#{csrf}"></head>))

        html =
          if data = conn.assigns[:auth_page] do
            json = data |> Jason.encode!() |> String.replace("<", "\\u003c")

            String.replace(
              html,
              "</head>",
              ~s(<script id="auth-page" type="application/json">#{json}</script></head>)
            )
          else
            html
          end

        conn |> put_resp_header("cache-control", "no-store") |> html(html)

      {:error, :enoent} ->
        conn
        |> put_status(:service_unavailable)
        |> text("Frontend assets are missing. Run pnpm run build in frontend/.")
    end
  end

  defp app_html do
    case Application.get_env(:nila, :vite_origin) do
      nil ->
        File.read(Application.app_dir(:nila, "priv/static/frontend/index.html"))

      origin ->
        # Phoenix owns the page/session; Vite owns modules and Fast Refresh.
        # The React preamble is required when Vite does not serve the HTML.
        html = File.read!(Path.expand("../../../frontend/index.html", __DIR__))

        scripts = """
        <script type="module">
          import RefreshRuntime from '#{origin}/@react-refresh';
          RefreshRuntime.injectIntoGlobalHook(window);
          window.$RefreshReg$ = () => {};
          window.$RefreshSig$ = () => (type) => type;
          window.__vite_plugin_react_preamble_installed__ = true;
        </script>
        <script type="module" src="#{origin}/@vite/client"></script>
        """

        {:ok,
         html
         |> String.replace("</head>", scripts <> "</head>")
         |> String.replace(~s(src="/src/main.tsx"), ~s(src="#{origin}/src/main.tsx"))}
    end
  end
end
