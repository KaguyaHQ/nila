defmodule Nila.Gst.Extraction.Sales.MistralOCR do
  @behaviour Nila.Gst.Extraction.Sales

  def provider, do: Nila.Gst.Extraction.Providers.Mistral.provider()
  def model, do: Nila.Gst.Extraction.Providers.Mistral.model()

  @impl true
  def per_call?, do: true

  @impl true
  def extract(bytes, opts), do: Nila.Gst.Extraction.Windowed.extract(:sales, bytes, opts)
end
