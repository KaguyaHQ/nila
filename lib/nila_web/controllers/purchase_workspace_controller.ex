defmodule NilaWeb.PurchaseWorkspaceController do
  use NilaWeb, :controller
  alias NilaWeb.Gst.{PurchaseWorkspace, PurchaseWorkspaceJson}

  def show(conn, %{"client_id" => id, "period" => period} = params) do
    scope = conn.assigns[:current_scope]

    with :ok <- access(scope),
         true <- is_binary(params["q"] || "") and is_binary(params["filter"] || "register"),
         {client_id, ""} when client_id > 0 and client_id <= 9_223_372_036_854_775_807 <-
           Integer.parse(id),
         true <- Regex.match?(~r/\A\d{4}-\d{2}\z/, period),
         {:ok, date} <- Date.from_iso8601(period <> "-01"),
         true <- date.year >= 2017,
         {:ok, data} <- PurchaseWorkspace.load(scope, client_id, period) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> json(PurchaseWorkspaceJson.build(scope, data, period, date, params))
    else
      {:error, :unauthenticated} -> error(conn, 401, "Sign in to continue.")
      {:error, :forbidden} -> error(conn, 403, "Verify your account and join a firm to continue.")
      {:error, :not_found} -> error(conn, 404, "This client is not available.")
      _ -> error(conn, 400, "Choose a valid client and month.")
    end
  end

  defp access(nil), do: {:error, :unauthenticated}
  defp access(%{user: %{confirmed_at: nil}}), do: {:error, :forbidden}
  defp access(%{current_org: nil}), do: {:error, :forbidden}
  defp access(_), do: :ok

  defp error(conn, status, message),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(status)
      |> json(%{error: message})
end
