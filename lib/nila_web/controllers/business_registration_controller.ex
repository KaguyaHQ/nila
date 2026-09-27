defmodule NilaWeb.BusinessRegistrationController do
  use NilaWeb, :controller

  alias Nila.Accounts
  alias Nila.Business.Access
  alias NilaWeb.UserAuth

  def create(conn, %{"business" => business_attrs} = params) do
    case conn.assigns[:current_scope] do
      %{user: %{confirmed_at: confirmed} = user} when not is_nil(confirmed) ->
        create_for_existing_user(conn, user, business_attrs)

      nil ->
        create_for_new_user(conn, Map.get(params, "user", %{}), business_attrs)

      _ ->
        redirect(conn, to: ~p"/users/confirm")
    end
  end

  def create(conn, _params), do: signup_error(conn, %Ecto.Changeset{}, %{}, %{})

  defp create_for_existing_user(conn, user, business_attrs) do
    case Access.create_business_for_user(user, business_attrs) do
      {:ok, %{client: client}} ->
        redirect(conn, to: "/app/business/#{client.id}/invoices")

      {:error, %Ecto.Changeset{} = changeset} ->
        signup_error(conn, changeset, %{}, business_attrs)

      {:error, _reason} ->
        signup_error(conn, %Ecto.Changeset{}, %{}, business_attrs)
    end
  end

  defp create_for_new_user(conn, user_attrs, business_attrs) do
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

    page_data = %{
      errors: errors,
      business_name: business_attrs["name"] || business_attrs[:name],
      gstin: business_attrs["gstin"] || business_attrs[:gstin],
      name: user_attrs["name"] || user_attrs[:name],
      email: user_attrs["email"] || user_attrs[:email]
    }

    page_data =
      case conn.assigns[:current_scope] do
        %{user: %{email: email}} -> Map.put(page_data, :signedInEmail, email)
        _ -> page_data
      end

    conn
    |> put_status(:unprocessable_entity)
    |> NilaWeb.AuthPageController.page("business_signup", page_data)
  end
end
