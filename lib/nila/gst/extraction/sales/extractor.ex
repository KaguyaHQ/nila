defmodule Nila.Gst.Extraction.Sales.Extractor do
  @behaviour Nila.Gst.Extraction.Sales

  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.Pipeline

  def provider, do: OpenAICompatibleChat.provider()
  def model, do: OpenAICompatibleChat.model()

  @impl true
  def per_call?, do: true

  @impl true
  def extract(bytes, opts) do
    defaults = Application.get_env(:nila, __MODULE__, [])
    Pipeline.extract(:sales, bytes, Keyword.merge(defaults, opts))
  end
end
