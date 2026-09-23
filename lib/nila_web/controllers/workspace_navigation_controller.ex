defmodule NilaWeb.WorkspaceNavigationController do
  use NilaWeb, :controller
  alias NilaWeb.WorkspaceNavigation, as: Navigation

  def show(conn, _), do: dispatch(conn, nil)
  def update(conn, params), do: dispatch(conn, params)

  defp dispatch(conn, params) do
    scope = conn.assigns[:current_scope]
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    case scope do
      %{user: %{}, current_org: %{}} ->
        if is_nil(params) do
          {conn, workspace} = Navigation.read(conn, scope)
          json(conn, %{workspace: workspace})
        else
          case Navigation.validate(scope, params) do
            {:ok, workspace} ->
              conn |> Navigation.put(scope, workspace) |> json(%{workspace: workspace})

            {:error, _} ->
              conn |> put_status(422) |> json(%{error: "Workspace is not available."})
          end
        end

      _ ->
        conn |> put_status(401) |> json(%{error: "Sign in to continue."})
    end
  end
end
