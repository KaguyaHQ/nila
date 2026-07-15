defmodule NilaWeb.UserRegistrationController do
  use NilaWeb, :controller

  alias Nila.Accounts
  alias NilaWeb.UserAuth

  def create(conn, %{"signup_session_token" => token}) when is_binary(token) and token != "" do
    case Accounts.get_user_by_session_token(token) do
      nil ->
        conn
        |> put_flash(:error, "Could not sign you in. Please try again.")
        |> redirect(to: ~p"/users/log_in")

      user ->
        conn
        |> put_flash(:info, "Firm created. Check your email to verify your account.")
        |> UserAuth.log_in_user(user)
    end
  end

  def create(conn, %{"signup" => params}) do
    case Accounts.register_user_with_org(params) do
      {:ok, %{user: user}} ->
        Accounts.deliver_user_confirmation_instructions(user, fn token ->
          url(~p"/users/confirm/#{token}")
        end)

        conn
        |> put_flash(:info, "Firm created. Check your email to verify your account.")
        |> UserAuth.log_in_user(user)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not create your firm. Check the details and try again.")
        |> redirect(to: ~p"/users/sign_up")
    end
  end
end
