defmodule NilaWeb.ClientContextController do
  use NilaWeb, :controller

  alias Nila.Clients

  def update(conn, %{"id" => client_id} = params) do
    org_id = conn.assigns.current_scope.current_org.id

    case Clients.get_client(org_id, client_id) do
      {:ok, client} ->
        conn
        |> put_session(:current_client_id, client.id)
        |> redirect(to: safe_return_to(params["return_to"], client))

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "That client is not available.")
        |> redirect(to: ~p"/clients")
    end
  end

  defp safe_return_to(path, client) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"),
      do: path,
      else: NilaWeb.GoTo.sales_home(client)
  end

  defp safe_return_to(_path, client), do: NilaWeb.GoTo.sales_home(client)
end
