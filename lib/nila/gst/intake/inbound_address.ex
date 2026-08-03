defmodule Nila.Gst.Intake.InboundAddress do
  @moduledoc """
  The per-client, per-period address a chase email asks to be replied to.

  Routing is the whole point: the address carries who and which month, so an
  arrival is attributed by construction instead of guessed from the sender.
  That is what lets Nila stay out of `gmail.readonly` — we never read a
  mailbox, we hand out an address we already understand.

  Local part is `n.<org_id>.<client_id>.<yyyymm>.<signature>`. The org travels
  with the address so resolution stays on the ordinary tenancy-scoped path.
  The signature is a truncated HMAC over all three: an address is unguessable
  and untamperable, so a stranger cannot post attachments into a client's month
  by editing one they were forwarded.
  """

  @prefix "n"
  @signature_length 12

  @doc """
  Builds the full reply address for a client and period, or an error when
  inbound is not configured.
  """
  def build(org_id, client_id, period) do
    with {:ok, secret} <- secret(),
         {:ok, domain} <- domain(),
         {:ok, compact} <- compact_period(period) do
      parts = [@prefix, org_id, client_id, compact]
      {:ok, Enum.join(parts ++ [sign(secret, parts)], ".") <> "@" <> domain}
    end
  end

  @doc """
  Resolves an address back to the org, client, and period it was issued for.

  Accepts the bare address or a `"Name <addr>"` header value, and tolerates the
  `+tag` suffix some clients append on reply.
  """
  def parse(address) when is_binary(address) do
    with {:ok, secret} <- secret(),
         {:ok, local} <- local_part(address),
         [@prefix, org_id, client_id, compact, signature] <- String.split(local, "."),
         {org_id, ""} <- Integer.parse(org_id),
         {client_id, ""} <- Integer.parse(client_id),
         {:ok, period} <- expand_period(compact),
         true <- valid_signature?(secret, [@prefix, org_id, client_id, compact], signature) do
      {:ok, %{org_id: org_id, client_id: client_id, period: period}}
    else
      false -> {:error, :bad_signature}
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, :unrecognized_address}
    end
  end

  def parse(_address), do: {:error, :unrecognized_address}

  @doc """
  Picks the address Nila issued out of a list of recipients.

  Resend delivers every recipient it saw; a reply usually carries the firm's
  own address alongside ours, and a forwarded thread can carry several.
  """
  def find(recipients) when is_list(recipients) do
    Enum.find_value(recipients, {:error, :no_inbound_recipient}, fn recipient ->
      case parse(recipient) do
        {:ok, routing} -> {:ok, routing}
        {:error, _reason} -> nil
      end
    end)
  end

  @doc "True when inbound routing is configured well enough to hand out addresses."
  def configured? do
    match?({:ok, _secret}, secret()) and match?({:ok, _domain}, domain())
  end

  defp sign(secret, parts) do
    :hmac
    |> :crypto.mac(:sha256, secret, Enum.join(parts, ":"))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, @signature_length)
    |> String.downcase()
  end

  defp valid_signature?(secret, parts, signature) do
    expected = sign(secret, parts)

    byte_size(expected) == byte_size(signature) and
      Plug.Crypto.secure_compare(expected, String.downcase(signature))
  end

  defp local_part(address) do
    address
    |> extract_angle_addr()
    |> String.split("@")
    |> case do
      [local, _domain] -> {:ok, local |> String.trim() |> strip_tag() |> String.downcase()}
      _malformed -> {:error, :unrecognized_address}
    end
  end

  defp extract_angle_addr(address) do
    case Regex.run(~r/<([^>]+)>/, address) do
      [_full, inner] -> inner
      nil -> address
    end
  end

  defp strip_tag(local), do: local |> String.split("+") |> List.first()

  defp compact_period(<<year::binary-size(4), "-", month::binary-size(2)>>),
    do: {:ok, year <> month}

  defp compact_period(_period), do: {:error, :invalid_period}

  defp expand_period(<<year::binary-size(4), month::binary-size(2)>>),
    do: {:ok, year <> "-" <> month}

  defp expand_period(_compact), do: {:error, :invalid_period}

  defp secret do
    case config(:secret) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :inbound_not_configured}
    end
  end

  defp domain do
    case config(:domain) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :inbound_not_configured}
    end
  end

  defp config(key), do: Application.get_env(:nila, __MODULE__, []) |> Keyword.get(key)
end
