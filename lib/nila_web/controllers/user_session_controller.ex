defmodule NilaWeb.UserSessionController do
  use NilaWeb, :controller

  alias Nila.Accounts
  alias NilaWeb.UserAuth

  @dev_login? Application.compile_env(:nila, :dev_routes, false)

  if @dev_login? do
    def create(conn, %{"dev_login" => "true", "email" => email}) do
      case Accounts.get_user_by_email(email) do
        %{active: true} = user ->
          if Enum.any?(Nila.Development.quick_login_users(), &(&1.email == email)),
            do: UserAuth.log_in_user(conn, user),
            else: reject_login(conn)

        _ ->
          reject_login(conn)
      end
    end
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      UserAuth.log_in_user(conn, user, user_params)
    else
      reject_login(conn)
    end
  end

  def create(conn, _params), do: reject_login(conn)

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp reject_login(conn) do
    conn
    |> put_flash(:error, "Invalid email or password.")
    |> put_flash(:email, get_in(conn.params, ["user", "email"]) || conn.params["email"])
    |> redirect(to: ~p"/users/log_in")
  end
end
