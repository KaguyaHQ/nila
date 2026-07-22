defmodule Nila.Gst.PurchaseExtractor.MistralOCR do
  @behaviour Nila.Gst.PurchaseExtractor

  def provider, do: Nila.Gst.MistralOCR.provider()
  def model, do: Nila.Gst.MistralOCR.model()

  @impl true
  def extract(bytes, opts), do: Nila.Gst.MistralOCR.extract(:purchase, bytes, opts)
end
