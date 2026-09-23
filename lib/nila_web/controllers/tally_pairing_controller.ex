defmodule NilaWeb.TallyPairingController do
  use NilaWeb, :controller

  alias Nila.RateLimiter
  alias Nila.TallyDevices

  @exchange_scale_ms :timer.minutes(1)
  @exchange_limit 60
  @global_exchange_limit 10_000

  # Pairing UI is shelved. Never issue a code with a dead approval URL.
  def create(conn, _params), do: error(conn, :gone, "pairing_unavailable")

  def exchange(conn, %{"device_code" => device_code})
      when is_binary(device_code) and byte_size(device_code) <= 128 do
    with :allow <-
           RateLimiter.check(
             "tally_pairing:exchange:global",
             @exchange_scale_ms,
             @global_exchange_limit
           ),
         :allow <-
           RateLimiter.check(secret_bucket(device_code), @exchange_scale_ms, @exchange_limit) do
      exchange_pairing(conn, device_code)
    else
      :deny -> rate_limited(conn, 60)
    end
  end

  def exchange(conn, _params), do: error(conn, :unprocessable_entity, "invalid_request")

  def revoke(conn, _params) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         device when not is_nil(device) <- TallyDevices.authenticate_device(token),
         {:ok, _device} <- TallyDevices.revoke_device(device) do
      conn
      |> no_store()
      |> send_resp(:no_content, "")
    else
      _reason -> error(conn, :unauthorized, "invalid_device")
    end
  end

  defp exchange_pairing(conn, device_code) do
    case TallyDevices.exchange_pairing(device_code) do
      {:ok, %{device: device, token: token}} ->
        conn
        |> no_store()
        |> json(%{
          status: "linked",
          device_id: device.id,
          device_token: token,
          websocket_url: websocket_url()
        })

      {:error, :pending} ->
        conn
        |> no_store()
        |> put_status(:accepted)
        |> json(%{status: "pending", retry_after: 2})

      {:error, :expired} ->
        error(conn, :gone, "expired")

      {:error, reason} when reason in [:not_found, :inactive_org] ->
        error(conn, :not_found, "invalid_pairing")

      {:error, _reason} ->
        error(conn, :service_unavailable, "pairing_failed")
    end
  end

  defp websocket_url do
    uri = URI.parse(NilaWeb.Endpoint.url())
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    URI.to_string(%{uri | scheme: scheme, path: "/connector/websocket", query: "vsn=2.0.0"})
  end

  defp secret_bucket(device_code) do
    digest = :crypto.hash(:sha256, device_code) |> Base.encode16(case: :lower)
    "tally_pairing:exchange:#{digest}"
  end

  defp error(conn, status, code) do
    conn
    |> no_store()
    |> put_status(status)
    |> json(%{error: code})
  end

  defp rate_limited(conn, retry_after_seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
    |> error(:too_many_requests, "rate_limited")
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
