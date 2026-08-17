defmodule Nila.Gst.Extraction.Sales.Vision do
  @behaviour Nila.Gst.Extraction.Sales

  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.VisionPipeline

  def provider, do: OpenAICompatibleChat.provider()
  def model, do: OpenAICompatibleChat.model()

  @impl true
  def per_call?, do: true

  @impl true
  def extract(bytes, opts), do: VisionPipeline.extract(:sales, bytes, opts)
end
