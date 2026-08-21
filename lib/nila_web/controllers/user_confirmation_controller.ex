defmodule NilaWeb.UserConfirmationController do
  use NilaWeb, :controller

  alias Nila.Accounts

  def confirm(conn, %{"token" => token}) do
    case Accounts.confirm_user(token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email verified.")
        |> redirect(to: verified_redirect_path(conn))

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Verification link is invalid or expired.")
        |> redirect(to: ~p"/users/log_in")
    end
  end

  defp verified_redirect_path(%{assigns: %{current_scope: %{}}}), do: ~p"/sales-bills"
  defp verified_redirect_path(_conn), do: ~p"/users/log_in"
end
