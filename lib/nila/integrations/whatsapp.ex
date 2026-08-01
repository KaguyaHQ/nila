defmodule Nila.Integrations.WhatsApp do
  @behaviour Nila.Integrations.WhatsAppAdapter

  @moduledoc """
  WhatsApp Cloud API adapter for inbound media and outbound chase templates.
  """

  @graph_url "https://graph.facebook.com/v20.0"

  require Logger

  @impl true
  def normalize(payload, _opts) when is_map(payload) do
    messages = messages(payload)
    events = Enum.flat_map(messages, &message_events/1)
    ignored = length(messages) - length(events)

    if ignored > 0, do: Logger.debug("Ignoring unsupported WhatsApp messages", count: ignored)
    {:ok, events}
  end

  @impl true
  def send_message(connection, recipient, draft, template_name)
      when is_binary(recipient) and is_binary(draft) and is_binary(template_name) do
    post_message(connection, %{
      "messaging_product" => "whatsapp",
      "to" => recipient,
      "type" => "template",
      "template" => %{
        "name" => template_name,
        "language" => %{"code" => "en"},
        "components" => [
          %{
            "type" => "body",
            "parameters" => [%{"type" => "text", "text" => draft}]
          }
        ]
      }
    })
  end

  @impl true
  def send_completeness_request(
        connection,
        recipient,
        period_label,
        template_name,
        yes_payload,
        no_payload
      )
      when is_binary(recipient) and is_binary(period_label) and is_binary(template_name) and
             is_binary(yes_payload) and is_binary(no_payload) do
    post_message(connection, %{
      "messaging_product" => "whatsapp",
      "to" => recipient,
      "type" => "template",
      "template" => %{
        "name" => template_name,
        "language" => %{"code" => "en"},
        "components" => [
          %{
            "type" => "body",
            "parameters" => [%{"type" => "text", "text" => period_label}]
          },
          quick_reply("0", yes_payload),
          quick_reply("1", no_payload)
        ]
      }
    })
  end

  @impl true
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

  defp message_events(%{"image" => image, "id" => message_id} = message) do
    [media_attachment(image, message_id, message["from"], "image")]
  end

  defp message_events(%{"document" => document, "id" => message_id} = message) do
    [media_attachment(document, message_id, message["from"], "document")]
  end

  defp message_events(
         %{
           "text" => %{"body" => body},
           "id" => message_id,
           "from" => sender
         } = message
       ) do
    [
      %{
        type: :text,
        body: body,
        sender: sender,
        source_ref: "whatsapp:#{message_id}",
        provider_context_ref: get_in(message, ["context", "id"])
      }
    ]
  end

  defp message_events(
         %{
           "button" => %{"payload" => payload} = button,
           "id" => message_id,
           "from" => sender
         } = message
       ) do
    [
      button_reply(
        payload,
        button["text"],
        message_id,
        sender,
        get_in(message, ["context", "id"])
      )
    ]
  end

  defp message_events(
         %{
           "interactive" => %{"button_reply" => %{"id" => payload} = button},
           "id" => message_id,
           "from" => sender
         } = message
       ) do
    [
      button_reply(
        payload,
        button["title"],
        message_id,
        sender,
        get_in(message, ["context", "id"])
      )
    ]
  end

  defp message_events(_message), do: []

  defp media_attachment(media, message_id, sender, fallback_name) do
    media_id = Map.fetch!(media, "id")
    content_type = Map.get(media, "mime_type", "application/octet-stream")

    %{
      type: :media,
      media_id: media_id,
      filename:
        Map.get(media, "filename") || "#{fallback_name}-#{media_id}#{extension(content_type)}",
      content_type: content_type,
      sender: sender,
      source_ref: "whatsapp:#{message_id}:#{media_id}"
    }
  end

  defp button_reply(payload, text, message_id, sender, context_ref) do
    %{
      type: :button_reply,
      payload: payload,
      text: text,
      sender: sender,
      source_ref: "whatsapp:#{message_id}",
      provider_context_ref: context_ref
    }
  end

  defp quick_reply(index, payload) do
    %{
      "type" => "button",
      "sub_type" => "quick_reply",
      "index" => index,
      "parameters" => [%{"type" => "payload", "payload" => payload}]
    }
  end

  defp post_message(connection, body) do
    token = Map.fetch!(connection.credentials, "access_token")
    url = "#{@graph_url}/#{connection.external_account_id}/messages"
    options = [auth: {:bearer, token}, json: body] ++ req_options()

    case Req.post(url, options) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status, body: response}} ->
        {:error, {:whatsapp_send_error, status, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp req_options,
    do: Application.get_env(:nila, __MODULE__, []) |> Keyword.get(:req_options, [])

  defp extension("application/pdf"), do: ".pdf"
  defp extension("image/jpeg"), do: ".jpg"
  defp extension("image/png"), do: ".png"
  defp extension(_content_type), do: ".bin"
end
