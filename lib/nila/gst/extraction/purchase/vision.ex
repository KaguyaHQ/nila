defmodule Nila.Gst.Extraction.Purchase.Vision do
  @behaviour Nila.Gst.Extraction.Purchase

  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.VisionPipeline

  def provider, do: OpenAICompatibleChat.provider()
  def model, do: OpenAICompatibleChat.model()

  @impl true
  def per_call?, do: true

  @impl true
  def extract(bytes, opts), do: VisionPipeline.extract(:purchase, bytes, opts)
end
