defmodule NilaWeb.UserSettingsController do
  use NilaWeb, :controller

  alias Nila.Accounts
  alias NilaWeb.UserAuth

  def update_password(conn, %{"password_user" => user_params}) do
    user = conn.assigns.current_scope.user
    current_password = Map.get(user_params, "current_password", "")

    case Accounts.update_user_password(user, current_password, user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Password updated.")
        |> put_session(:user_return_to, ~p"/settings/account")
        |> UserAuth.log_in_user(user)

      {:error, _changeset} ->
        conn
        |> put_flash(
          :error,
          "Could not update password. Check your current password and try again."
        )
        |> redirect(to: ~p"/settings/account")
    end
  end
end
