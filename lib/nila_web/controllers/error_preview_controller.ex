if Application.compile_env(:nila, :dev_routes) do
  defmodule NilaWeb.ErrorPreviewController do
    @moduledoc """
    Renders an error page on demand at `/dev/errors/:status`.

    `debug_errors: true` in dev means a real 404 always shows the Plug debugger,
    so without this route the error pages are only reachable in production. To
    check the *real* path — status code, headers, no-layout rendering — flip
    `debug_errors: false` in `config/dev.exs` for a minute and don't commit it.
    """
    use NilaWeb, :controller

    @statuses ~w(404 500)

    def show(conn, %{"status" => status}) when status in @statuses do
      conn
      |> put_status(String.to_integer(status))
      |> put_view(html: NilaWeb.ErrorHTML)
      |> put_root_layout(html: false)
      |> put_layout(html: false)
      |> render("#{status}.html")
    end
  end
end
