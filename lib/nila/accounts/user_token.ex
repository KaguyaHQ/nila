defmodule Nila.Accounts.UserToken do
  use Nila.Schema
  import Ecto.Query

  @hash_algorithm :sha256
  @rand_size 32
  @session_validity_in_days 60
  @invite_validity_in_days 14
  @confirmation_validity_in_days 7
  @reset_password_validity_in_days 1
  @change_email_validity_in_days 1

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string

    belongs_to :user, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %__MODULE__{token: hash_token(token), context: "session", user_id: user.id}}
  end

  @doc """
  Builds an invite token for `user`.

  Returns `{encoded_token, schema}`. The URL-safe `encoded_token` goes in the
  invite link; only its hash is stored, so a leaked database row cannot be used
  to accept an invite.
  """
  def build_invite_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(token, padding: false),
     %__MODULE__{
       token: hash_token(token),
       context: "invite",
       sent_to: user.email,
       user_id: user.id
     }}
  end

  @doc """
  Query that resolves a non-expired invite token to its user.

  Returns `{:ok, query}` or `:error` if the token is not valid base64.
  """
  def verify_invite_token_query(token) do
    verify_user_token_query(token, "invite", @invite_validity_in_days)
  end

  def build_confirmation_token(user) do
    build_encoded_token(user, "confirm", user.email)
  end

  def verify_confirmation_token_query(token) do
    verify_user_token_query(token, "confirm", @confirmation_validity_in_days)
  end

  def build_reset_password_token(user) do
    build_encoded_token(user, "reset_password", user.email)
  end

  def verify_reset_password_token_query(token) do
    verify_user_token_query(token, "reset_password", @reset_password_validity_in_days)
  end

  def build_change_email_token(user, email) do
    build_encoded_token(user, "change_email", email)
  end

  def verify_change_email_token_query(token) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false) do
      hashed_token = hash_token(decoded_token)

      query =
        from token in by_token_and_context_query(hashed_token, "change_email"),
          where: token.inserted_at > ago(@change_email_validity_in_days, "day"),
          select: token

      {:ok, query}
    end
  end

  def verify_session_token_query(token) do
    hashed_token = hash_token(token)

    query =
      from token in by_token_and_context_query(hashed_token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: user

    {:ok, query}
  end

  def by_token_and_context_query(token, context) do
    from __MODULE__, where: [token: ^token, context: ^context]
  end

  def by_user_and_contexts_query(user, :all) do
    from token in __MODULE__, where: token.user_id == ^user.id
  end

  def by_user_and_contexts_query(user, [_ | _] = contexts) do
    from token in __MODULE__, where: token.user_id == ^user.id and token.context in ^contexts
  end

  defp verify_user_token_query(token, context, validity_in_days) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false) do
      hashed_token = hash_token(decoded_token)

      query =
        from token in by_token_and_context_query(hashed_token, context),
          join: user in assoc(token, :user),
          where: token.inserted_at > ago(^validity_in_days, "day"),
          select: user

      {:ok, query}
    end
  end

  defp build_encoded_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(token, padding: false),
     %__MODULE__{
       token: hash_token(token),
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  defp hash_token(token), do: :crypto.hash(@hash_algorithm, token)
end
