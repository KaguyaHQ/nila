defmodule NilaWeb.LegacyWorkspaceController do
  use NilaWeb, :controller

  # Existing bookmarks and retained LiveView flows enter the maintained React UI.
  # These routes use the same authentication/firm pipeline as /app.
  def show(conn, _params), do: move(conn, "/app" <> conn.request_path)

  def purchase_register(conn, params) do
    filter = params["filter"] || "register"
    base = "/app/gst/#{segment(params["client_id"])}/#{segment(params["period"])}/purchases"

    if filter in ["register", "gstr2b"] do
      query =
        conn.query_params
        |> Map.delete("filter")
        |> Map.put("source", if(filter == "gstr2b", do: "gstr2b", else: "purchases"))

      redirect(conn, to: base <> "/register?" <> URI.encode_query(query))
    else
      move(conn, base <> "/review")
    end
  end

  def purchase_review(conn, %{"client_id" => client, "period" => period, "item_id" => item}) do
    move(conn, "/app/gst/#{segment(client)}/#{segment(period)}/purchases/review/#{segment(item)}")
  end

  def gstr2b(conn, params) do
    case params do
      %{"client_id" => client, "period" => period} ->
        move(conn, "/app/gst/#{segment(client)}/#{segment(period)}/purchases")

      _ ->
        redirect(conn, to: "/app/clients")
    end
  end

  defp move(conn, path) do
    query = conn.query_string
    redirect(conn, to: if(query == "", do: path, else: path <> "?" <> query))
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
