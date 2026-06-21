defmodule Nila.Documents.Extractor do
  @callback extract(pdf_bytes :: binary(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  # Supported opts include :filename and optional :on_progress callback.
  # The callback receives coarse stages such as :reading and :extracting.
end
