defmodule NilaWeb.LocalUploadController do
  @moduledoc """
  Stands in for the bucket in dev and test.

  Intake presigns a `PUT` and the browser sends the file straight there. On
  Cloudflare that endpoint is R2; on disk there is nothing to presign against,
  so this route accepts the same request and writes it through `Nila.Storage`.
  Without it the upload path would only exist in production — the one place it
  cannot be exercised before shipping.

  The signed token *is* the authorization, and it carries the storage key. A
  caller who could name its own key could write anywhere in the bucket.
  """

  use NilaWeb, :controller

  alias Nila.Storage

  # Matches the intake ceiling in `NilaWeb.Gst.UploadLive`.
  @max_bytes 50_000_000

  def update(conn, %{"token" => token}) do
    with {:ok, key} <- Storage.Local.verify_upload_token(token),
         {:ok, body, conn} <- read_full_body(conn),
         {:ok, _stored} <- Storage.put(key, body, content_type: content_type(conn)) do
      send_resp(conn, :ok, "")
    else
      {:error, :too_large} -> send_resp(conn, :request_entity_too_large, "")
      {:error, reason} when reason in [:invalid, :expired] -> send_resp(conn, :forbidden, "")
      {:error, _reason} -> send_resp(conn, :bad_request, "")
    end
  end

  def update(conn, _params), do: send_resp(conn, :forbidden, "")

  defp read_full_body(conn), do: read_full_body(conn, [], 0)

  defp read_full_body(conn, acc, size) do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}

      {:more, chunk, conn} ->
        size = size + byte_size(chunk)

        if size > @max_bytes,
          do: {:error, :too_large},
          else: read_full_body(conn, [chunk | acc], size)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [type | _rest] -> type |> String.split(";") |> hd() |> String.trim()
      [] -> "application/octet-stream"
    end
  end
end
