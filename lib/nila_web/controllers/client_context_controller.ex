defmodule NilaWeb.ClientContextController do
  use NilaWeb, :controller

  alias Nila.Clients

  def update(conn, %{"id" => client_id} = params) do
    org_id = conn.assigns.current_scope.current_org.id

    case Clients.get_client(org_id, client_id) do
      {:ok, client} ->
        {conn, remembered} = NilaWeb.WorkspaceNavigation.read(conn, conn.assigns.current_scope)
        destination = safe_return_to(params["return_to"], client)

        workspace =
          (NilaWeb.WorkspaceNavigation.from_path(URI.parse(destination).path || "") || remembered ||
             %{"period" => NilaWeb.GoTo.period(nil, nil), "section" => "sales"})
          |> Map.put("clientId", client.id)

        workspace =
          case NilaWeb.WorkspaceNavigation.validate(conn.assigns.current_scope, workspace) do
            {:ok, valid} ->
              valid

            _ ->
              %{
                "clientId" => client.id,
                "period" => NilaWeb.GoTo.period(nil, nil),
                "section" => "sales"
              }
          end

        conn
        |> NilaWeb.WorkspaceNavigation.put(conn.assigns.current_scope, workspace)
        |> redirect(to: destination)

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "That client is not available.")
        |> redirect(to: ~p"/app/clients")
    end
  end

  defp safe_return_to(path, client) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"),
      do: path,
      else: NilaWeb.GoTo.sales_home(client)
  end

  defp safe_return_to(_path, client), do: NilaWeb.GoTo.sales_home(client)
end
