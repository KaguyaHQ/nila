defmodule NilaWeb.ClientImportController do
  use NilaWeb, :controller

  def template(conn, _params) do
    {:ok, bytes} = Nila.Clients.Import.template()

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> send_download({:binary, bytes},
      filename: "Nila-client-import.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
  end
end
