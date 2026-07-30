defmodule Nila.Gst.Extraction.Purchase.MistralOCR do
  @behaviour Nila.Gst.Extraction.Purchase

  # Two models read a packet now — the OCR model transcribes it, the text model
  # segments and extracts — and the attempt row carries one name, so it carries
  # both. See `Nila.Gst.Extraction.Pipeline`.
  def provider, do: Nila.Gst.Extraction.Providers.Mistral.provider()

  def model do
    Nila.Gst.Extraction.Providers.Mistral.model() <>
      "+" <> Nila.Gst.Extraction.Providers.MistralChat.model()
  end

  @impl true
  def per_call?, do: true

  @impl true
  def extract(bytes, opts), do: Nila.Gst.Extraction.Pipeline.extract(:purchase, bytes, opts)
end
