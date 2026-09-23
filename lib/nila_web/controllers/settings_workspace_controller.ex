defmodule NilaWeb.SettingsWorkspaceController do
  use NilaWeb, :controller

  alias Nila.{Accounts, Clients, Orgs}
  alias Nila.Accounts.Policy
  alias NilaWeb.UserAuth

  plug :authorize

  def show(conn, _params), do: json(conn, snapshot(conn.assigns.current_scope))

  def name(conn, params) do
    case Accounts.update_user(conn.assigns.current_scope.user, Map.take(params, ["name"])) do
      {:ok, _} -> json(conn, %{message: "Name updated."})
      {:error, reason} -> failure(conn, reason)
    end
  end

  def email(conn, params) do
    case Accounts.deliver_user_update_email_instructions(
           conn.assigns.current_scope.user,
           password(params),
           Map.take(params, ["email"]),
           &url(~p"/settings/profile/confirm_email/#{&1}")
         ) do
      {:ok, email} -> json(conn, %{message: "A confirmation link has been sent to #{email}."})
      {:error, reason} -> failure(conn, reason)
    end
  end

  def password(conn, params) do
    case Accounts.update_user_password(
           conn.assigns.current_scope.user,
           password(params),
           Map.take(params, ["password", "password_confirmation"])
         ) do
      {:ok, user} ->
        conn
        |> UserAuth.create_user_session(user)
        |> json(%{
          message: "Password updated.",
          redirect_to: "/app/settings/security?updated=password"
        })

      {:error, reason} ->
        failure(conn, reason)
    end
  end

  def sessions(conn, _params) do
    conn
    |> UserAuth.clear_all_user_sessions(conn.assigns.current_scope.user)
    |> json(%{message: "Signed out everywhere.", redirect_to: "/users/log_in"})
  end

  def firm(conn, params) do
    case Orgs.update_org(
           conn.assigns.current_scope.current_org,
           Map.take(params, ["name", "contact_phone"])
         ) do
      {:ok, _} -> json(conn, %{message: "Firm details saved."})
      {:error, reason} -> failure(conn, reason)
    end
  end

  def invite(conn, params) do
    changeset = Accounts.change_invite(Map.take(params, ["name", "email", "role"]))

    with {:ok, attrs} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, _} <-
           Accounts.invite_user(
             conn.assigns.current_scope.current_org,
             attrs,
             &url(~p"/users/invite/#{&1}")
           ) do
      json(conn, %{message: "Invitation sent."})
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def member(conn, params) do
    scope = conn.assigns.current_scope
    members = Orgs.list_memberships(scope.current_org.id)
    member = Enum.find(members, &(to_string(&1.id) == params["id"]))

    result =
      case {member, params} do
        {nil, _} ->
          {:error, :not_found}

        {member, %{"action" => "role", "role" => role}} when is_binary(role) ->
          Orgs.update_membership_role(member, role)

        {member, %{"action" => "active", "active" => active}} when is_boolean(active) ->
          cond do
            member.user_id == scope.user.id ->
              {:error, :self_disable}

            not active and member.role == "owner" and member.user.active and
                Enum.count(members, &(&1.role == "owner" and &1.user.active)) <= 1 ->
              {:error, :last_owner}

            true ->
              Accounts.set_user_active(member.user, active)
          end

        {member, %{"action" => "resend"}} ->
          if member.user.active and is_nil(member.user.hashed_password),
            do:
              Accounts.resend_invite(
                member.user,
                scope.current_org,
                &url(~p"/users/invite/#{&1}")
              ),
            else: {:error, :not_invited}

        _ ->
          {:error, :invalid}
      end

    case result do
      {:ok, _} ->
        json(conn, %{
          message:
            if(params["action"] == "resend", do: "Invitation resent.", else: "User updated.")
        })

      {:error, reason} ->
        failure(conn, reason)
    end
  end

  defp authorize(conn, _) do
    scope = conn.assigns[:current_scope]
    action = action_name(conn)

    cond do
      is_nil(scope) ->
        conn |> put_status(401) |> json(%{error: "Sign in to continue."}) |> halt()

      not scope.user.active or is_nil(scope.user.confirmed_at) or is_nil(scope.current_org) ->
        forbidden(conn)

      action == :firm and not Policy.can?(scope, :manage_settings) ->
        forbidden(conn)

      action in [:invite, :member] and not Policy.can?(scope, :manage_users) ->
        forbidden(conn)

      true ->
        put_resp_header(conn, "cache-control", "private, no-store")
    end
  end

  defp forbidden(conn),
    do:
      conn
      |> put_status(403)
      |> json(%{error: "You don't have access to these settings."})
      |> halt()

  defp password(params),
    do: if(is_binary(params["current_password"]), do: params["current_password"], else: "")

  defp snapshot(scope) do
    manage_users = Policy.can?(scope, :manage_users)
    members = if manage_users, do: Orgs.list_memberships(scope.current_org.id), else: []

    %{
      user: %{
        id: scope.user.id,
        name: scope.user.name,
        email: scope.user.email,
        org: scope.current_org.name,
        role: Policy.role_label(scope.membership.role)
      },
      firm: Map.take(scope.current_org, [:name, :contact_phone]),
      can_manage_firm: Policy.can?(scope, :manage_settings),
      can_manage_users: manage_users,
      clients: Enum.map(Clients.list_clients(scope.current_org.id), &Map.take(&1, [:id, :name])),
      roles:
        Enum.map(Policy.assignable_roles(), fn {label, value} -> %{label: label, value: value} end),
      members:
        Enum.map(members, fn member ->
          locked = member.role == "owner" and Enum.count(members, &(&1.role == "owner")) <= 1

          last_active =
            member.role == "owner" and member.user.active and
              Enum.count(members, &(&1.role == "owner" and &1.user.active)) <= 1

          %{
            id: member.id,
            name: member.user.name,
            email: member.user.email,
            role: member.role,
            active: member.user.active,
            invited: member.user.active and is_nil(member.user.hashed_password),
            self: member.user_id == scope.user.id,
            can_change_role: not locked,
            can_toggle_active: member.user_id != scope.user.id and not last_active
          }
        end)
    }
  end

  defp failure(conn, %Ecto.Changeset{} = changeset) do
    fields =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, text ->
          String.replace(text, "%{#{key}}", to_string(value))
        end)
      end)

    conn |> put_status(422) |> json(%{error: "Check the highlighted fields.", fields: fields})
  end

  defp failure(conn, reason) do
    message =
      case reason do
        :last_owner -> "You can't remove or disable the firm's last owner."
        :self_disable -> "You can't disable your own account."
        :already_member -> "That person is already in this firm."
        :not_found -> "This user is not in your firm."
        :not_invited -> "This user has already accepted their invitation."
        _ -> "Could not save this change. Please try again."
      end

    conn |> put_status(if(reason == :not_found, do: 404, else: 422)) |> json(%{error: message})
  end
end
