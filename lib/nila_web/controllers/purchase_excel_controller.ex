defmodule NilaWeb.PurchaseExcelController do
  use NilaWeb, :controller

  def template(conn, _) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> send_download(
      {:file, Application.app_dir(:nila, "priv/templates/Nila-purchases-template.xlsx")},
      filename: "Nila-purchases-template.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
  end
end
