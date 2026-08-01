defmodule Nila.Gst.Extraction.Sales do
  @moduledoc """
  Per-page, one-invoice-per-page extraction for a sales-bills PDF.

  A month's outward invoices are dumped into one PDF (one invoice per page in
  the scanned packets sent to the auditor), so extraction runs
  `extraction_target: "per_page"` against the sales-invoice schema and returns
  one artifact per page that `Nila.Gst.Sales.Gstr1.normalize_invoice/1` consumes.

  The outward mirror of `Nila.Gst.Extraction.Purchase`: the implementation is
  selected via `Application.get_env(:nila, :sales_extractor,
  Nila.Gst.Extraction.Sales.MistralOCR)`. Mistral OCR is the operational default;
  tests override it with a test-only extractor and LlamaExtract remains an
  explicit benchmark adapter.

  A successful `extract/2` returns:

      {:ok, %{
        pages: [page_artifact],           # string-keyed maps for Gstr1
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
  each provider stage, so the caller persists a separate audit row for each
  independently measurable stage.
  """
  @callback per_call?() :: boolean()

  @optional_callbacks per_call?: 0

  # Supported opts: :filename, an optional :on_progress callback receiving
  # extraction progress events, and :per_call for extractors that declare
  # `per_call?/0`.
end
