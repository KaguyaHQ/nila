defmodule NilaWeb.Webhooks.ResendController do
  @moduledoc """
  Receives Resend inbound-email webhooks.

  Does as little as possible: verify the Svix signature, enqueue, return 200.
  Resend stores the message and retries when we fail, so a slow or broken
  ingest costs a retry rather than a lost document — but only if we answer
  quickly and let the worker do the fetching.
  """

  use NilaWeb, :controller

  require Logger

  alias Nila.Integrations.ResendInboundWorker

  # Svix's own recommended tolerance; older timestamps are replays.
  @tolerance_seconds 300

  def ingest(conn, params) do
    with :ok <- verify_signature(conn),
         {:ok, email} <- inbound_email(params),
         :ok <- enqueue(email) do
      json(conn, %{ok: true})
    else
      {:error, :bad_signature} ->
        send_resp(conn, 401, "invalid signature")

      {:error, :not_configured} ->
        Logger.error("Resend webhook is not configured")
        send_resp(conn, 503, "webhook unavailable")

      {:error, {:enqueue_failed, reason}} ->
        Logger.error("Resend webhook enqueue failed", reason: inspect(reason))
        send_resp(conn, 503, "webhook unavailable")

      {:error, reason} ->
        Logger.warning("Resend webhook ignored", reason: inspect(reason))
        json(conn, %{ok: true})
    end
  end

  defp inbound_email(%{"type" => "email.received", "data" => %{"email_id" => email_id} = data})
       when is_binary(email_id) do
    {:ok,
     %{
       email_id: email_id,
       to: List.wrap(data["to"]),
       from: data["from"],
       subject: data["subject"],
       text: data["text"]
     }}
  end

  defp inbound_email(%{"type" => type}), do: {:error, {:unhandled_event, type}}
  defp inbound_email(_params), do: {:error, :unrecognized_payload}

  defp enqueue(email) do
    inserter = Application.get_env(:nila, :resend_job_inserter, Oban)

    changeset =
      ResendInboundWorker.new(
        %{
          email_id: email.email_id,
          to: email.to,
          from: email.from,
          subject: email.subject,
          text: email.text
        },
        unique: [period: {7, :day}, fields: [:worker, :args]]
      )

    case inserter.insert(changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  # Svix signs "<id>.<timestamp>.<raw body>" with the base64 payload of a
  # `whsec_`-prefixed secret, and sends a space-delimited list of versioned
  # signatures. Any one of them matching is a pass.
  defp verify_signature(conn) do
    with {:ok, secret} <- signing_secret(),
         {:ok, id} <- header(conn, "svix-id"),
         {:ok, timestamp} <- header(conn, "svix-signature-timestamp"),
         {:ok, signatures} <- header(conn, "svix-signature"),
         :ok <- check_timestamp(timestamp) do
      expected =
        :hmac
        |> :crypto.mac(:sha256, secret, "#{id}.#{timestamp}.#{raw_body(conn)}")
        |> Base.encode64()

      signatures
      |> String.split(" ", trim: true)
      |> Enum.map(&strip_version/1)
      |> Enum.any?(&secure_compare(&1, expected))
      |> case do
        true -> :ok
        false -> {:error, :bad_signature}
      end
    end
  end

  defp header(conn, "svix-signature-timestamp"), do: header(conn, "svix-timestamp")

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _rest] when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :bad_signature}
    end
  end

  defp check_timestamp(timestamp) do
    with {seconds, ""} <- Integer.parse(timestamp),
         true <- abs(System.system_time(:second) - seconds) <= @tolerance_seconds do
      :ok
    else
      _stale -> {:error, :bad_signature}
    end
  end

  defp strip_version(signature) do
    case String.split(signature, ",", parts: 2) do
      [_version, encoded] -> encoded
      [encoded] -> encoded
    end
  end

  defp raw_body(conn) do
    conn.private[:raw_body] |> List.wrap() |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_left, _right), do: false

  defp signing_secret do
    with value when is_binary(value) and value != "" <- config(:signing_secret),
         {:ok, secret} <- decode_secret(value) do
      {:ok, secret}
    else
      _missing -> {:error, :not_configured}
    end
  end

  defp decode_secret("whsec_" <> encoded), do: Base.decode64(encoded)
  defp decode_secret(encoded), do: Base.decode64(encoded)

  defp config(key), do: Application.get_env(:nila, __MODULE__, []) |> Keyword.get(key)
end
