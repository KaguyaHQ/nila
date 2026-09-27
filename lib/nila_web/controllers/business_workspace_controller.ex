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

  def create(conn, %{"business" => attrs}) do
    case conn.assigns[:current_scope] do
      %{user: %{active: true, confirmed_at: confirmed} = user} when not is_nil(confirmed) ->
        case Access.create_business_for_user(user, attrs) do
          {:ok, %{client: client}} ->
            conn
            |> put_status(:created)
            |> json(%{business: Map.take(client, [:id, :name, :gstin])})

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = NilaWeb.AuthPageController.errors(changeset)

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Check the business details.", errors: errors})

          {:error, _} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Could not add the business."})
        end

      nil ->
        conn |> put_status(:unauthorized) |> json(%{error: "Sign in to continue."})

      _ ->
        conn |> put_status(:forbidden) |> json(%{error: "Verify your email first."})
    end
  end

  def create(conn, _params),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "Enter a business name and GSTIN."})
end
