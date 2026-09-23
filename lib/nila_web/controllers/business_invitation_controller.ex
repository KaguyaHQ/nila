defmodule NilaWeb.BusinessInvitationController do
  use NilaWeb, :controller
  alias Nila.Business.Access

  def create(conn, %{"client_id" => client_id} = params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Access.invite(conn.assigns[:current_scope], client_id, params["invitation"]) do
      {:ok, result} ->
        base =
          Application.get_env(:nila, :business_url, NilaWeb.Endpoint.url())
          |> String.trim_trailing("/")

        url =
          if result.token,
            do: base <> "/users/invite/" <> result.token,
            else: base <> "/users/log_in"

        json(conn, %{
          invitation_url: url,
          email: result.user.email,
          already_active: result.already_active
        })

      {:error, :forbidden} ->
        error(conn, 403, "Only a firm owner can invite business users.")

      {:error, :not_found} ->
        error(conn, 404, "This client is not available.")

      {:error, :firm_user} ->
        error(conn, 422, "This email belongs to a firm user. Use a separate business email.")

      {:error, :other_business} ->
        error(conn, 422, "This email already has access to another business.")

      {:error, :inactive_user} ->
        error(conn, 422, "This account is disabled.")

      {:error, _} ->
        error(conn, 422, "Enter a name and valid email address.")
    end
  end

  defp error(conn, status, message), do: conn |> put_status(status) |> json(%{error: message})
end
