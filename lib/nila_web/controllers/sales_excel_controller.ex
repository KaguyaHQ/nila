defmodule NilaWeb.SalesExcelController do
  use NilaWeb, :controller

  def template(conn, _) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> send_download(
      {:file, Application.app_dir(:nila, "priv/templates/Nila-sales-template.xlsx")},
      filename: "Nila-sales-template.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
  end
end
