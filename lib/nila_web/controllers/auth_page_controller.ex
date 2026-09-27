defmodule NilaWeb.AuthPageController do
  use NilaWeb, :controller
  alias Nila.Accounts

  @dev_login? Application.compile_env(:nila, :dev_routes, false)

  def login(conn, _) do
    notice = get_session(conn, :auth_notice) || Phoenix.Flash.get(conn.assigns.flash, :info)

    conn
    |> delete_session(:auth_notice)
    |> page("login", %{users: quick_login_users(), info: notice})
  end

  def forgot(conn, _), do: page(conn, "forgot")

  def business_signup(conn, _), do: page(conn, "business_signup")

  def reset(conn, %{"token" => token}) do
    page(conn, "reset", %{valid: not is_nil(Accounts.get_user_by_reset_password_token(token))})
  end

  def invite(conn, %{"token" => token}) do
    user = Accounts.get_user_by_invite_token(token)

    page(conn, "invite", %{
      valid: not is_nil(user),
      email: user && user.email,
      name: user && user.name
    })
  end

  def confirmation(conn, _) do
    user = conn.assigns.current_scope.user
    continue_to = if conn.assigns.current_scope.business_client, do: "/app/business", else: "/app"

    page(conn, "confirmation", %{
      email: user.email,
      confirmed: not is_nil(user.confirmed_at),
      continueTo: continue_to
    })
  end

  def forgot_submit(conn, %{"user" => %{"email" => email}}) when is_binary(email) do
    Accounts.deliver_user_reset_password_instructions(
      email,
      &url(~p"/users/reset_password/#{&1}")
    )

    conn
    |> put_flash(
      :info,
      "If your email exists in Nila, password reset instructions have been sent."
    )
    |> redirect(to: ~p"/users/log_in")
  end

  def reset_submit(conn, %{"token" => token, "user" => params}) when is_map(params) do
    with user when not is_nil(user) <- Accounts.get_user_by_reset_password_token(token),
         {:ok, _user} <- Accounts.reset_user_password(user, token, params) do
      conn
      |> put_flash(:info, "Your password has been reset. Sign in with your new password.")
      |> redirect(to: ~p"/users/log_in")
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        page(put_status(conn, 422), "reset", %{valid: true, errors: errors(changeset)})

      _ ->
        page(put_status(conn, 422), "reset", %{valid: false})
    end
  end

  def resend(conn, _) do
    user = conn.assigns.current_scope.user

    case Accounts.deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}")) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Verification email sent to #{user.email}.")
        |> redirect(to: ~p"/users/confirm")

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not send the verification email. Try again.")
        |> redirect(to: ~p"/users/confirm")
    end
  end

  def confirm_email(conn, %{"token" => token}) do
    case Accounts.update_user_email(conn.assigns.current_scope.user, token) do
      {:ok, _} -> redirect(conn, to: ~p"/app/settings/profile?email=confirmed")
      {:error, _} -> redirect(conn, to: ~p"/app/settings/profile?email=invalid")
    end
  end

  def page(conn, kind, attrs \\ %{}) do
    data =
      Map.merge(
        %{
          kind: kind,
          action: conn.request_path,
          email: Phoenix.Flash.get(conn.assigns.flash, :email),
          info: Phoenix.Flash.get(conn.assigns.flash, :info),
          error: Phoenix.Flash.get(conn.assigns.flash, :error),
          errors: %{},
          users: []
        },
        attrs
      )

    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> assign(:auth_page, data)
    |> NilaWeb.ReactAppController.index(%{})
  end

  def errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  if @dev_login? do
    defp quick_login_users,
      do: Nila.Development.quick_login_users()
  else
    defp quick_login_users, do: []
  end
end
