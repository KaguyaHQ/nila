defmodule Nila.Gst.Extraction.Sales.MistralOCR do
  @behaviour Nila.Gst.Extraction.Sales

  def provider, do: Nila.Gst.Extraction.MistralOCR.provider()
  def model, do: Nila.Gst.Extraction.MistralOCR.model()

  @impl true
  def extract(bytes, opts), do: Nila.Gst.Extraction.MistralOCR.extract(:sales, bytes, opts)
end
