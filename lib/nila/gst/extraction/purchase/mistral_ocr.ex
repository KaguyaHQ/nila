defmodule Nila.Gst.Extraction.Purchase.MistralOCR do
  @behaviour Nila.Gst.Extraction.Purchase

  def provider, do: Nila.Gst.Extraction.Providers.Mistral.provider()
  def model, do: Nila.Gst.Extraction.Providers.Mistral.model()

  @impl true
  def extract(bytes, opts),
    do: Nila.Gst.Extraction.Providers.Mistral.extract(:purchase, bytes, opts)
end
