defmodule NilaWeb.Gstr2bController do
  use NilaWeb, :controller

  def download(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, statement, json} <- Nila.Gst.Portal.Gstr2b.download(conn.assigns.current_scope, id) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> send_download({:binary, json},
        filename: "GSTR2B_#{statement.gstin}_#{statement.period}.json",
        content_type: "application/json"
      )
    else
      _ -> send_resp(conn, 404, "Statement not found.")
    end
  end
end
