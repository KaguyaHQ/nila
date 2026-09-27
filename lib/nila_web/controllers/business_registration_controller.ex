defmodule NilaWeb.BusinessRegistrationController do
  use NilaWeb, :controller

  alias Nila.Accounts
  alias Nila.Business.Access
  alias NilaWeb.UserAuth

  def create(conn, %{"user" => user_attrs, "business" => business_attrs}) do
    case Access.register_business(user_attrs, business_attrs) do
      {:ok, %{user: user}} ->
        delivery =
          Accounts.deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}"))

        notice =
          case delivery do
            {:ok, _} -> "Check your email to confirm your account."
            {:error, _} -> "Your account was created. Use Resend verification email to try again."
          end

        conn
        |> put_flash(:info, notice)
        |> UserAuth.create_user_session(user)
        |> redirect(to: "/users/confirm")

      {:error, %Ecto.Changeset{} = changeset} ->
        signup_error(conn, changeset, user_attrs, business_attrs)

      {:error, :invalid_attrs} ->
        signup_error(conn, %Ecto.Changeset{}, user_attrs, business_attrs)

      {:error, _reason} ->
        signup_error(conn, %Ecto.Changeset{}, user_attrs, business_attrs)
    end
  end

  def create(conn, _params), do: signup_error(conn, %Ecto.Changeset{}, %{}, %{})

  defp signup_error(conn, changeset, user_attrs, business_attrs) do
    errors =
      NilaWeb.AuthPageController.errors(changeset)
      |> Enum.map(fn
        {key, message}
        when key in [
               :business_name,
               :gstin,
               :name,
               :email,
               :password,
               :password_confirmation
             ] ->
          {key, message}

        other ->
          other
      end)
      |> Enum.into(%{})

    conn
    |> put_status(:unprocessable_entity)
    |> NilaWeb.AuthPageController.page("business_signup", %{
      errors: errors,
      business_name: business_attrs["name"] || business_attrs[:name],
      gstin: business_attrs["gstin"] || business_attrs[:gstin],
      name: user_attrs["name"] || user_attrs[:name],
      email: user_attrs["email"] || user_attrs[:email]
    })
  end
end
