defmodule Nila.Business.Access do
  import Ecto.Query
  alias Nila.{Accounts, Clients, Repo}
  alias Nila.Accounts.{Policy, User, UserToken}
  alias Nila.Business.ClientAccess
  alias Nila.Orgs.Membership

  def client_for_user(user_id) do
    Repo.one(
      from a in ClientAccess,
        join: c in assoc(a, :client),
        where: a.user_id == ^user_id,
        select: c
    )
  end

  def invite(scope, client_id, attrs) do
    with :ok <- authorize(scope),
         {:ok, client_id} <- client_id(client_id),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         {:ok, fields} <- invitation_fields(attrs) do
      Repo.transact(fn ->
        with {:ok, user} <- find_or_create_user(fields),
             :ok <- business_only(user),
             {:ok, access} <- grant_access(user, client) do
          token = if is_nil(user.hashed_password), do: invitation_token(user)

          {:ok,
           %{
             user: user,
             client: client,
             access: access,
             token: token,
             already_active: not is_nil(user.hashed_password)
           }}
        end
      end)
    end
  end

  defp authorize(%{user: %{confirmed_at: confirmed}, current_org: %{}} = scope)
       when not is_nil(confirmed) do
    if Policy.can?(scope, :manage_users), do: :ok, else: {:error, :forbidden}
  end

  defp authorize(_), do: {:error, :forbidden}

  defp client_id(id) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
    do: {:ok, id}

  defp client_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} -> client_id(number)
      _ -> {:error, :not_found}
    end
  end

  defp client_id(_), do: {:error, :not_found}

  defp invitation_fields(attrs) when is_map(attrs) do
    {%{}, %{name: :string, email: :string}}
    |> Ecto.Changeset.cast(attrs, [:name, :email])
    |> Ecto.Changeset.update_change(:name, &String.trim/1)
    |> Ecto.Changeset.update_change(:email, &(String.trim(&1) |> String.downcase()))
    |> Ecto.Changeset.validate_required([:name, :email])
    |> Ecto.Changeset.validate_length(:name, max: 255)
    |> Ecto.Changeset.validate_length(:email, max: 255)
    |> Ecto.Changeset.validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> Ecto.Changeset.apply_action(:insert)
  end

  defp invitation_fields(_), do: {:error, :invalid_attrs}

  defp find_or_create_user(fields) do
    case Accounts.get_user_by_email(fields.email) do
      nil -> Accounts.create_user(fields)
      %User{active: false} -> {:error, :inactive_user}
      user -> {:ok, user}
    end
  end

  defp business_only(user) do
    if Repo.exists?(from m in Membership, where: m.user_id == ^user.id),
      do: {:error, :firm_user},
      else: :ok
  end

  defp grant_access(user, client) do
    case Repo.get_by(ClientAccess, user_id: user.id) do
      nil ->
        %ClientAccess{user_id: user.id, client_id: client.id}
        |> ClientAccess.changeset()
        |> Repo.insert()

      %ClientAccess{client_id: id} = access when id == client.id ->
        {:ok, access}

      _ ->
        {:error, :other_business}
    end
  end

  defp invitation_token(user) do
    Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["invite"]))
    {encoded_token, token} = UserToken.build_invite_token(user)
    Repo.insert!(token)
    encoded_token
  end
end
