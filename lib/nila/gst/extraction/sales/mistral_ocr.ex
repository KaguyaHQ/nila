defmodule Nila.Gst.Extraction.Sales.MistralOCR do
  @behaviour Nila.Gst.Extraction.Sales

  # Stage completion replaces these extractor defaults with the provider and
  # model that actually handled transcription, discovery, or extraction.
  def provider, do: Nila.Gst.Extraction.Providers.Mistral.provider()
  def model, do: Nila.Gst.Extraction.Providers.Mistral.model()

  @impl true
  def per_call?, do: true

  @impl true
  def extract(bytes, opts), do: Nila.Gst.Extraction.Pipeline.extract(:sales, bytes, opts)
end
