defmodule NilaWeb.BusinessWorkspaceController do
  use NilaWeb, :controller

  alias Nila.Business.Access

  def index(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    case conn.assigns[:current_scope] do
      %{user: %{id: user_id, active: true, confirmed_at: confirmed} = _user} = scope
      when not is_nil(confirmed) ->
        businesses =
          user_id
          |> Access.list_clients_for_user()
          |> Enum.map(&Map.take(&1, [:id, :name, :gstin]))

        json(conn, %{
          businesses: businesses,
          ca_workspace: %{
            available: not is_nil(scope.membership) and not is_nil(scope.current_org)
          }
        })

      nil ->
        conn |> put_status(:unauthorized) |> json(%{error: "Sign in to continue."})

      _ ->
        conn |> put_status(:forbidden) |> json(%{error: "Verify your email first."})
    end
  end
end
