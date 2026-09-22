defmodule NilaWeb.ReactAppController do
  use NilaWeb, :controller

  def index(conn, _params) do
    # Vite's hashed assets are built into the Phoenix release. No second server
    # or client-side credential store is needed to use the authenticated app.
    path = Application.app_dir(:nila, "priv/static/frontend/index.html")

    case File.read(path) do
      {:ok, html} ->
        csrf = Plug.CSRFProtection.get_csrf_token()

        html =
          String.replace(html, "</head>", ~s(<meta name="csrf-token" content="#{csrf}"></head>))

        conn |> put_resp_header("cache-control", "no-store") |> html(html)

      {:error, :enoent} ->
        conn
        |> put_status(:service_unavailable)
        |> text("Frontend assets are missing. Run npm run build in frontend/.")
    end
  end
end
