defmodule Nila.Accounts do
  import Ecto.Query

  alias Nila.Accounts.{User, UserNotifier, UserToken}
  alias Nila.Orgs
  alias Nila.Orgs.Org
  alias Nila.Repo

  def list_users do
    Repo.all(from user in User, order_by: [asc: user.name])
  end

  def list_users_for_org(org_id) do
    Repo.all(
      from user in User,
        join: membership in assoc(user, :memberships),
        where: membership.org_id == ^org_id,
        order_by: [asc: user.name]
    )
  end

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.one(from user in User, where: user.email == ^email)
  end

  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)

    # `valid_password?/2` is false for a nil user, so `and` short-circuits before
    # `user.active` is touched. A disabled user can never authenticate.
    if User.valid_password?(user, password) and user.active, do: user
  end

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def create_user!(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def register_user!(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert!()
  end

  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false, validate_email: false)
  end

  def change_user_email(user, attrs \\ %{}) do
    User.email_changeset(user, attrs, validate_email: false)
  end

  def change_user_password(user, attrs \\ %{}) do
    User.password_changeset(user, attrs, hash_password: false)
  end

  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(:crypto.hash(:sha256, token), "session"))
    :ok
  end

  def delete_all_user_tokens(user) do
    Repo.delete_all(UserToken.by_user_and_contexts_query(user, :all))
    :ok
  end

  def deliver_user_reset_password_instructions(email, url_fun)
      when is_binary(email) and is_function(url_fun, 1) do
    email = email |> String.trim() |> String.downcase()

    if user = get_user_by_email(email) do
      {encoded_token, user_token} = UserToken.build_reset_password_token(user)
      Repo.insert!(user_token)
      UserNotifier.deliver_reset_password_instructions(user, url_fun.(encoded_token))
    end

    :ok
  end

  def get_user_by_reset_password_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_reset_password_token_query(token) do
      Repo.one(query)
    else
      _ -> nil
    end
  end

  def reset_user_password(%User{} = user, token, attrs) when is_binary(token) do
    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_reset_password_token_query(token),
           %User{id: user_id} when user_id == user.id <- Repo.one(query),
           {:ok, user} <- user |> User.password_changeset(attrs) |> Repo.update() do
        Repo.delete_all(UserToken.by_user_and_contexts_query(user, :all))
        {:ok, user}
      else
        nil -> {:error, :not_found}
        :error -> {:error, :not_found}
        %User{} -> {:error, :not_found}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      end
    end)
  end

  def update_user_password(%User{} = user, current_password, attrs)
      when is_binary(current_password) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(current_password)

    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["session", "reset_password"]))
        {:ok, user}
      end
    end)
  end

  def deliver_user_update_email_instructions(%User{} = user, current_password, attrs, url_fun)
      when is_binary(current_password) and is_function(url_fun, 1) do
    changeset =
      user
      |> User.email_changeset(attrs)
      |> User.validate_current_password(current_password)

    if changeset.valid? do
      email = Ecto.Changeset.get_change(changeset, :email)
      {encoded_token, user_token} = UserToken.build_change_email_token(user, email)
      Repo.insert!(user_token)
      UserNotifier.deliver_update_email_instructions(user, email, url_fun.(encoded_token))
      {:ok, email}
    else
      {:error, changeset}
    end
  end

  def update_user_email(%User{} = user, token) when is_binary(token) do
    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token),
           %UserToken{user_id: user_id, sent_to: email} = user_token when user_id == user.id <-
             Repo.one(query),
           {:ok, user} <- user |> User.email_changeset(%{email: email}) |> Repo.update() do
        Repo.delete!(user_token)
        Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["change_email"]))
        {:ok, user}
      else
        nil -> {:error, :not_found}
        :error -> {:error, :not_found}
        %UserToken{} -> {:error, :not_found}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      end
    end)
  end

  def set_user_active(%User{} = user, active?) when is_boolean(active?) do
    user
    |> Ecto.Changeset.change(active: active?)
    |> Repo.update()
  end

  ## Self-serve registration

  @registration_with_org_types %{
    name: :string,
    email: :string,
    password: :string,
    password_confirmation: :string,
    org_name: :string
  }

  def change_user_registration_with_org(attrs \\ %{}) do
    {%{}, @registration_with_org_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@registration_with_org_types))
    |> Ecto.Changeset.validate_required([:name, :email, :password, :org_name])
    |> Ecto.Changeset.update_change(:email, &String.downcase(String.trim(&1)))
    |> Ecto.Changeset.update_change(:org_name, &String.trim/1)
    |> Ecto.Changeset.validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> Ecto.Changeset.validate_length(:password, min: 8, max: 72)
    |> Ecto.Changeset.validate_confirmation(:password, message: "does not match password")
  end

  def register_user_with_org(attrs) do
    changeset = change_user_registration_with_org(attrs)

    if changeset.valid? do
      signup = Ecto.Changeset.apply_changes(changeset)

      Repo.transact(fn ->
        with {:ok, user} <-
               User.registration_changeset(%User{}, signup, confirm: false) |> Repo.insert(),
             {:ok, org} <- Orgs.create_org(%{name: signup.org_name}),
             {:ok, membership} <- Orgs.add_user(org, user.id, "owner") do
          {:ok, %{user: user, org: org, membership: membership}}
        end
      end)
    else
      {:error, changeset}
    end
  end

  def deliver_user_confirmation_instructions(%User{confirmed_at: nil} = user, url_fun)
      when is_function(url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_confirmation_token(user)
    Repo.insert!(user_token)
    UserNotifier.deliver_confirmation_instructions(user, url_fun.(encoded_token))
  end

  def deliver_user_confirmation_instructions(%User{}, _url_fun), do: {:ok, nil}

  def confirm_user(token) when is_binary(token) do
    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_confirmation_token_query(token),
           %User{} = user <- Repo.one(query) do
        user = user |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now()) |> Repo.update!()
        Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["confirm"]))
        {:ok, user}
      else
        nil -> {:error, :not_found}
        :error -> {:error, :not_found}
      end
    end)
  end

  ## Invitations

  @invite_types %{name: :string, email: :string, role: :string}

  @doc """
  Builds the schemaless changeset behind the "invite user" form.
  """
  def change_invite(attrs \\ %{}) do
    {%{role: "member"}, @invite_types}
    |> Ecto.Changeset.cast(attrs, [:name, :email, :role])
    |> Ecto.Changeset.validate_required([:name, :email, :role])
    |> Ecto.Changeset.update_change(:email, &String.downcase(String.trim(&1)))
    |> Ecto.Changeset.validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> Ecto.Changeset.validate_inclusion(:role, ~w(owner admin member viewer))
  end

  @doc """
  Invites a user into `org` with a role.

  Creates the user (without a password, so they read as "Invited" until they
  accept) when the email is new, attaches a membership, mints an invite token,
  and emails the acceptance link built by `url_fun`. The user and membership are
  written in one transaction; the email is sent only after it commits.

  Returns `{:ok, user}`, `{:error, :already_member}`, or `{:error, changeset}`.
  """
  def invite_user(%Org{} = org, attrs, url_fun) when is_function(url_fun, 1) do
    email = attrs |> Map.fetch!(:email) |> String.trim() |> String.downcase()
    name = Map.fetch!(attrs, :name)
    role = Map.get(attrs, :role, "member")

    result =
      Repo.transact(fn ->
        with {:ok, user} <- get_or_create_user(email, name),
             {:ok, _membership} <- Orgs.add_user(org, user.id, role) do
          {encoded_token, user_token} = UserToken.build_invite_token(user)
          Repo.insert!(user_token)
          {:ok, {user, encoded_token}}
        else
          {:error, %Ecto.Changeset{} = changeset} ->
            if membership_taken?(changeset),
              do: {:error, :already_member},
              else: {:error, changeset}
        end
      end)

    with {:ok, {user, encoded_token}} <- result do
      UserNotifier.deliver_invitation(user, org, url_fun.(encoded_token))
      {:ok, user}
    end
  end

  @doc """
  Re-issues an invite link for an already-invited user and re-sends the email.
  """
  def resend_invite(%User{} = user, %Org{} = org, url_fun) when is_function(url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_invite_token(user)
    Repo.insert!(user_token)
    UserNotifier.deliver_invitation(user, org, url_fun.(encoded_token))
    {:ok, user}
  end

  @doc """
  Resolves a (non-expired) invite token to its user, or `nil`.
  """
  def get_user_by_invite_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_invite_token_query(token) do
      Repo.one(query)
    else
      _ -> nil
    end
  end

  @doc """
  Accepts an invitation: sets the password, confirms the account, and burns the
  outstanding invite tokens so the link is single-use.
  """
  def accept_invite(%User{} = user, attrs) do
    Repo.transact(fn ->
      with {:ok, user} <- user |> User.invite_acceptance_changeset(attrs) |> Repo.update() do
        Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["invite"]))
        {:ok, user}
      end
    end)
  end

  defp get_or_create_user(email, name) do
    case get_user_by_email(email) do
      nil -> create_user(%{email: email, name: name})
      %User{} = user -> {:ok, user}
    end
  end

  defp membership_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {field, {_msg, opts}} ->
      field in [:org_id, :user_id] and Keyword.get(opts, :constraint) == :unique
    end)
  end
end
