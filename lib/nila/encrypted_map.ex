defmodule Nila.EncryptedMap do
  @moduledoc """
  Ecto type for encrypted maps stored as binary columns.
  """

  use Ecto.Type

  @aad "nila:encrypted_map:v1"
  @nonce_size 12
  @tag_size 16

  def type, do: :binary

  def cast(nil), do: {:ok, nil}
  def cast(value) when is_map(value), do: {:ok, value}
  def cast(_value), do: :error

  def dump(nil), do: {:ok, nil}

  def dump(value) when is_map(value) do
    nonce = :crypto.strong_rand_bytes(@nonce_size)
    plaintext = :erlang.term_to_binary(value)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), nonce, plaintext, @aad, true)

    {:ok, nonce <> tag <> ciphertext}
  end

  def dump(_value), do: :error

  def load(nil), do: {:ok, nil}

  def load(<<nonce::binary-size(@nonce_size), tag::binary-size(@tag_size), ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), nonce, ciphertext, @aad, tag, false) do
      :error -> :error
      plaintext -> {:ok, :erlang.binary_to_term(plaintext)}
    end
  end

  def load(_value), do: :error

  defp key do
    case Application.get_env(:nila, __MODULE__, [])[:key] do
      nil -> raise "missing :nila, #{inspect(__MODULE__)} :key configuration"
      value -> normalize_key(value)
    end
  end

  defp normalize_key(value) when is_binary(value) do
    with {:ok, decoded} <- Base.decode64(value),
         32 <- byte_size(decoded) do
      decoded
    else
      _ -> :crypto.hash(:sha256, value)
    end
  end
end
