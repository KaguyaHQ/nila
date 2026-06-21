defmodule Nila.Integrations.WhatsApp do
  @behaviour Nila.Integrations.Connector

  @moduledoc """
  WhatsApp Cloud API inbound adapter.
  """

  @graph_url "https://graph.facebook.com/v20.0"

  @impl true
  def normalize(payload, _opts) when is_map(payload) do
    payload
    |> messages()
    |> Enum.flat_map(&message_attachments/1)
    |> then(&{:ok, &1})
  end

  def fetch_media(media_id, token) do
    with {:ok, media_url} <- fetch_media_url(media_id, token),
         {:ok, response} <- Req.get(media_url, auth: {:bearer, token}),
         %{status: status, body: bytes} when status in 200..299 <- response do
      {:ok, bytes}
    else
      %{status: status, body: body} -> {:error, {:whatsapp_media_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_media_url(media_id, token) do
    case Req.get("#{@graph_url}/#{media_id}", auth: {:bearer, token}) do
      {:ok, %{status: status, body: %{"url" => url}}} when status in 200..299 -> {:ok, url}
      {:ok, %{status: status, body: body}} -> {:error, {:whatsapp_media_url_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp messages(payload) do
    payload
    |> Map.get("entry", [])
    |> Enum.flat_map(&Map.get(&1, "changes", []))
    |> Enum.flat_map(&(get_in(&1, ["value", "messages"]) || []))
  end

  defp message_attachments(%{"image" => image, "id" => message_id}) do
    [media_attachment(image, message_id, "image")]
  end

  defp message_attachments(%{"document" => document, "id" => message_id}) do
    [media_attachment(document, message_id, "document")]
  end

  defp message_attachments(_message), do: []

  defp media_attachment(media, message_id, fallback_name) do
    media_id = Map.fetch!(media, "id")
    content_type = Map.get(media, "mime_type", "application/octet-stream")

    %{
      media_id: media_id,
      filename:
        Map.get(media, "filename") || "#{fallback_name}-#{media_id}#{extension(content_type)}",
      content_type: content_type,
      document_type: "purchase_order",
      source_ref: "whatsapp:#{message_id}:#{media_id}"
    }
  end

  defp extension("application/pdf"), do: ".pdf"
  defp extension("image/jpeg"), do: ".jpg"
  defp extension("image/png"), do: ".png"
  defp extension(_content_type), do: ".bin"
end
