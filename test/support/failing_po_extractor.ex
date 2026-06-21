defmodule Nila.FailingPoExtractor do
  @behaviour Nila.Documents.Extractor

  @impl true
  def extract(_pdf_bytes, _opts), do: {:error, :forced_extractor_error}
end
