defmodule NilaWeb.NoticeDocumentController do
  use NilaWeb, :controller

  def show(conn, %{"id" => id, "index" => index}) do
    with {id, ""} <- Integer.parse(id),
         {index, ""} when index >= 0 <- Integer.parse(index),
         {:ok, bytes} <-
           Nila.Notices.download(conn.assigns.current_scope.current_org.id, id, index) do
      conn
      |> put_resp_content_type("application/pdf")
      |> put_resp_header("content-disposition", "inline; filename=notice.pdf")
      |> put_resp_header("cache-control", "private, no-store")
      |> send_resp(200, bytes)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> text("Not found")

      {:error, :session_expired} ->
        conn
        |> put_status(:conflict)
        |> text(
          "GST login expired. Reconnect this client on the Notices screen, then open the PDF again."
        )

      {:error, _} ->
        conn
        |> put_status(:bad_gateway)
        |> text("Could not load the PDF. Reconnect the client's GST account or try again.")

      _ ->
        conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
