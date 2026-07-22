defmodule Nila.Gst.Extraction.Sales.LlamaExtract do
  @moduledoc """
  Real `Nila.Gst.Extraction.Sales` backed by LlamaExtract v2, per-page.

  Thin adapter over the shared `Nila.Gst.Extraction.Providers.Llama` engine, fixing
  the kind to `:sales`. Selected explicitly with `GST_OCR_PROVIDER=llama`;
  credentials alone never change the active provider.
  """
  @behaviour Nila.Gst.Extraction.Sales

  def provider, do: Nila.Gst.Extraction.Providers.Llama.provider()
  def model, do: Nila.Gst.Extraction.Providers.Llama.model()

  @impl true
  def extract(bytes, opts), do: Nila.Gst.Extraction.Providers.Llama.extract(:sales, bytes, opts)
end
