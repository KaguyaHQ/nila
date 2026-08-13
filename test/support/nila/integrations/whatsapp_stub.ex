defmodule Nila.Integrations.WhatsAppStub do
  @behaviour Nila.Integrations.WhatsAppAdapter

  @impl true
  def normalize(payload, opts), do: Nila.Integrations.WhatsApp.normalize(payload, opts)

  @impl true
  def fetch_media(_media_id, _token) do
    Process.get(:whatsapp_media_result, {:ok, Process.get(:whatsapp_media_bytes, "%PDF-1.4")})
  end

  @impl true
  def send_message(_connection, recipient, draft, template_name) do
    send(self(), {:whatsapp_send_message, recipient, draft, template_name})
    {:ok, %{"messages" => [%{"id" => "wamid.test"}]}}
  end
end
