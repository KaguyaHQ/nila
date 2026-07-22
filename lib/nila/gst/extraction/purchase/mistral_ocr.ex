defmodule Nila.Gst.Extraction.Purchase.MistralOCR do
  @behaviour Nila.Gst.Extraction.Purchase

  def provider, do: Nila.Gst.Extraction.MistralOCR.provider()
  def model, do: Nila.Gst.Extraction.MistralOCR.model()

  @impl true
  def extract(bytes, opts), do: Nila.Gst.Extraction.MistralOCR.extract(:purchase, bytes, opts)
end
