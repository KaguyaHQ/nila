defmodule NilaWeb.Webhooks.WhatsAppController do
  use NilaWeb, :controller

  alias Nila.Integrations
  alias Nila.Integrations.WhatsAppIngestWorker

  def verify(conn, params) do
    mode = params["hub.mode"]
    token = params["hub.verify_token"]
    challenge = params["hub.challenge"]

    if mode == "subscribe" and token == verify_token() do
      send_resp(conn, 200, challenge || "")
    else
      send_resp(conn, 403, "forbidden")
    end
  end

  def ingest(conn, params) do
    with :ok <- verify_signature(conn),
         {:ok, phone_number_id} <- phone_number_id(params),
         %{} = connection <-
           Integrations.get_connection_by_provider_external_account("whatsapp", phone_number_id),
         {:ok, _job} <-
           %{connection_id: connection.id, payload: params}
           |> WhatsAppIngestWorker.new()
           |> Oban.insert() do
      json(conn, %{ok: true})
    else
      {:error, :bad_signature} -> send_resp(conn, 401, "invalid signature")
      _error -> json(conn, %{ok: true})
    end
  end

  defp phone_number_id(payload) do
    phone_number_id =
      payload
      |> Map.get("entry", [])
      |> Enum.flat_map(&Map.get(&1, "changes", []))
      |> Enum.find_value(&get_in(&1, ["value", "metadata", "phone_number_id"]))

    if phone_number_id, do: {:ok, phone_number_id}, else: {:error, :missing_phone_number_id}
  end

  defp verify_signature(conn) do
    signature = Plug.Conn.get_req_header(conn, "x-hub-signature-256") |> List.first()
    raw_body = conn.private[:raw_body] || []
    body = raw_body |> Enum.reverse() |> IO.iodata_to_binary()

    expected =
      "sha256=" <>
        (:crypto.mac(:hmac, :sha256, app_secret(), body) |> Base.encode16(case: :lower))

    if secure_compare(signature || "", expected) do
      :ok
    else
      {:error, :bad_signature}
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
