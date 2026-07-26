defmodule Nila.Gst.Extraction.Purchase do
  @moduledoc """
  Per-page, multi-invoice extraction for a purchase-bills PDF.

  A month's bills are many invoices dumped into one PDF, so extraction runs
  `extraction_target: "per_page"` against the purchase-invoice schema and
  returns one artifact per page (with `is_invoice` / `continuation_of_previous`
  flags) that `Nila.Gst.Purchase.Books` assembles into invoices.

  The implementation is selected via `Application.get_env(:nila,
  :purchase_extractor, Nila.Gst.Extraction.Purchase.MistralOCR)`. Mistral OCR is
  the operational default; tests override it with a test-only extractor and
  LlamaExtract remains an explicit benchmark adapter.

  A successful `extract/2` returns:

      {:ok, %{
        pages: [page_artifact],           # string-keyed maps for Books
        images: %{"page_01.png" => bytes} # rendered page images, by basename
      }}

  Each `page_artifact` carries `"page"`, `"image"` (`"images/page_NN.png"`),
  `"data"` (the extracted fields), and `"confidence"`.
  """

  @type audit :: %{
          optional(:provider_request_id) => String.t() | nil,
          optional(:http_status) => integer(),
          optional(:source_page_count) => non_neg_integer(),
          optional(:usage) => map(),
          optional(:raw_response) => binary()
        }

  @callback extract(source_bytes :: binary(), opts :: keyword()) ::
              {:ok,
               %{
                 required(:pages) => [map()],
                 required(:images) => %{String.t() => binary()},
                 optional(:audit) => audit()
               }}
              | {:error, term()}
              | {:error, term(), audit()}

  @doc """
  True when `extract/2` accepts a `:per_call` wrapper and applies it around
  every provider request — a windowed extractor makes many requests per source,
  and the caller persists one audit row per request rather than one per source.
  """
  @callback per_call?() :: boolean()

  @optional_callbacks per_call?: 0

  # Supported opts: :filename, an optional :on_progress callback receiving
  # coarse stages such as :rendering, :reading, :extracting, and :per_call for
  # extractors that declare `per_call?/0`.
end
