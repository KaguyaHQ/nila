defmodule Nila.Integrations.WhatsAppReply do
  @moduledoc "Signed machine-readable replies for period-specific WhatsApp questions."

  @prefix "nila-completeness-v1"
  @decisions ~w(client_yes client_no)

  def sign(ask_ref, decision) when decision in @decisions do
    with {:ok, secret} <- secret(),
         {:ok, ask_ref} <- cast_ask_ref(ask_ref) do
      message = "#{ask_ref}:#{decision}"

      signature =
        :crypto.mac(:hmac, :sha256, secret, message) |> Base.url_encode64(padding: false)

      {:ok, Enum.join([@prefix, ask_ref, decision, signature], ".")}
    end
  end

  def sign(_ask_ref, _decision), do: {:error, :invalid_decision}

  def verify(payload) when is_binary(payload) do
    with [@prefix, ask_ref, decision, signature] <- String.split(payload, "."),
         true <- decision in @decisions,
         {:ok, ask_ref} <- cast_ask_ref(ask_ref),
         {:ok, secret} <- secret(),
         expected <-
           :crypto.mac(:hmac, :sha256, secret, "#{ask_ref}:#{decision}")
           |> Base.url_encode64(padding: false),
         true <- Plug.Crypto.secure_compare(expected, signature) do
      {:ok, %{ask_ref: ask_ref, decision: decision}}
    else
      {:error, :not_configured} = error -> error
      _invalid -> {:error, :invalid_reply}
    end
  end

  def verify(_payload), do: {:error, :invalid_reply}

  defp cast_ask_ref(ask_ref) do
    case Ecto.UUID.cast(ask_ref) do
      {:ok, ask_ref} -> {:ok, ask_ref}
      :error -> {:error, :invalid_ask_ref}
    end
  end

  defp secret do
    case Application.get_env(:nila, :whatsapp_completeness_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      _missing -> {:error, :not_configured}
    end
  end
end
