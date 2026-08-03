defmodule NilaWeb.Webhooks.WhatsAppController do
  use NilaWeb, :controller

  require Logger

  alias Nila.Integrations
  alias Nila.Integrations.WhatsAppIngestWorker

  def verify(conn, params) do
    mode = params["hub.mode"]
    token = params["hub.verify_token"]
    challenge = params["hub.challenge"]

    configured_token = verify_token()

    if mode == "subscribe" and is_binary(configured_token) and configured_token != "" and
         secure_compare(token || "", configured_token) do
      send_resp(conn, 200, challenge || "")
    else
      send_resp(conn, 403, "forbidden")
    end
  end

  def ingest(conn, params) do
    with :ok <- verify_signature(conn),
         {:ok, deliveries} <- deliveries(params),
         :ok <- deliveries |> route_deliveries() |> enqueue() do
      json(conn, %{ok: true})
    else
      {:error, :bad_signature} ->
        send_resp(conn, 401, "invalid signature")

      {:error, :not_configured} ->
        Logger.error("WhatsApp webhook is not configured")
        send_resp(conn, 503, "webhook unavailable")

      {:error, {:enqueue_failed, reason}} ->
        Logger.error("WhatsApp webhook enqueue failed", reason: inspect(reason))
        send_resp(conn, 503, "webhook unavailable")

      {:error, reason} ->
        Logger.warning("WhatsApp webhook ignored", reason: inspect(reason))
        json(conn, %{ok: true})
    end
  end

  defp deliveries(payload) do
    deliveries =
      for entry <- Map.get(payload, "entry", []),
          change <- Map.get(entry, "changes", []),
          phone_number_id = get_in(change, ["value", "metadata", "phone_number_id"]),
          is_binary(phone_number_id) do
        scoped_entry = Map.put(entry, "changes", [change])
        {phone_number_id, Map.put(payload, "entry", [scoped_entry])}
      end

    if deliveries == [], do: {:error, :missing_phone_number_id}, else: {:ok, deliveries}
  end

  defp route_deliveries(deliveries) do
    Enum.flat_map(deliveries, fn {phone_number_id, payload} ->
      case Integrations.get_connection_by_provider_external_account("whatsapp", phone_number_id) do
        nil ->
          Logger.warning("WhatsApp webhook ignored unknown phone-number ID",
            phone_number_id: phone_number_id
          )

          []

        connection ->
          [{connection.id, payload}]
      end
    end)
  end

  defp enqueue(deliveries) do
    inserter = Application.get_env(:nila, :whatsapp_job_inserter, Oban)

    Enum.reduce_while(deliveries, :ok, fn {connection_id, payload}, :ok ->
      changeset =
        WhatsAppIngestWorker.new(
          %{connection_id: connection_id, payload: payload},
          unique: [period: {7, :day}, fields: [:worker, :args]]
        )

      case inserter.insert(changeset) do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:enqueue_failed, reason}}}
      end
    end)
  end

  defp verify_signature(conn) do
    signature = Plug.Conn.get_req_header(conn, "x-hub-signature-256") |> List.first()
    raw_body = conn.private[:raw_body] || []
    body = raw_body |> Enum.reverse() |> IO.iodata_to_binary()

    case app_secret() do
      secret when is_binary(secret) and secret != "" ->
        expected =
          "sha256=" <>
            (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))

        if secure_compare(signature || "", expected), do: :ok, else: {:error, :bad_signature}

      _missing ->
        {:error, :not_configured}
    end
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp verify_token do
    Application.get_env(:nila, __MODULE__, []) |> Keyword.get(:verify_token, "")
  end

  defp app_secret do
    Application.get_env(:nila, __MODULE__, []) |> Keyword.get(:app_secret, "")
  end
end
