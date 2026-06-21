defmodule Nila.Accounts.User do
  use Nila.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :active, :boolean, default: true
    field :password, :string, virtual: true, redact: true
    field :current_password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime_usec

    has_many :memberships, Nila.Orgs.Membership
    has_many :orgs, through: [:memberships, :org]

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :active])
    |> validate_required([:email, :name])
    |> update_change(:email, &String.downcase/1)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> unique_constraint(:email)
  end

  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> changeset(attrs)
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
    |> maybe_confirm(opts)
  end

  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> update_change(:email, &String.downcase/1)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> maybe_validate_unique_email(opts)
  end

  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  @doc """
  Sets the password for an invited user accepting their invitation, confirming
  the account in the same step.
  """
  def invite_acceptance_changeset(user, attrs, opts \\ []) do
    user
    |> password_changeset(attrs, opts)
    |> put_change(:confirmed_at, DateTime.utc_now())
  end

  def valid_password?(%__MODULE__{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  def validate_current_password(changeset, password) do
    if valid_password?(changeset.data, password) do
      changeset
    else
      add_error(changeset, :current_password, "is not valid")
    end
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      |> validate_length(:password, max: 72, count: :bytes)
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  defp maybe_confirm(changeset, opts) do
    if Keyword.get(opts, :confirm, true) do
      put_change(changeset, :confirmed_at, DateTime.utc_now())
    else
      changeset
    end
  end

  defp maybe_validate_unique_email(changeset, opts) do
    if Keyword.get(opts, :validate_email, true) do
      changeset
      |> unsafe_validate_unique(:email, Nila.Repo)
      |> unique_constraint(:email)
    else
      changeset
    end
  end
end
