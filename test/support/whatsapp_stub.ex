defmodule Nila.WhatsAppStub do
  def normalize(payload, opts), do: Nila.Integrations.WhatsApp.normalize(payload, opts)
  def fetch_media(_media_id, _token), do: {:ok, Process.get(:whatsapp_media_bytes, "%PDF-1.4")}
end
