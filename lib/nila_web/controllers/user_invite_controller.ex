defmodule NilaWeb.UserInviteController do
  use NilaWeb, :controller

  alias Nila.Accounts
  alias NilaWeb.UserAuth

  def create(conn, %{"token" => token, "user" => user_params}) do
    case Accounts.get_user_by_invite_token(token) do
      nil ->
        conn
        |> put_flash(:error, "That invite link is invalid or has expired.")
        |> redirect(to: ~p"/users/log_in")

      user ->
        case Accounts.accept_invite(user, user_params) do
          {:ok, user} ->
            conn
            |> put_flash(:info, "Welcome to Nila. You're signed in.")
            |> UserAuth.log_in_user(user)

          {:error, changeset} ->
            conn
            |> put_status(422)
            |> NilaWeb.AuthPageController.page("invite", %{
              valid: true,
              name: user.name,
              email: user.email,
              errors: NilaWeb.AuthPageController.errors(changeset)
            })
        end
    end
  end
end
