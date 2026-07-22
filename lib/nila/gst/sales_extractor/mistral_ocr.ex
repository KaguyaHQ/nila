defmodule Nila.Gst.SalesExtractor.MistralOCR do
  @behaviour Nila.Gst.SalesExtractor

  def provider, do: Nila.Gst.MistralOCR.provider()
  def model, do: Nila.Gst.MistralOCR.model()

  @impl true
  def extract(bytes, opts), do: Nila.Gst.MistralOCR.extract(:sales, bytes, opts)
end
