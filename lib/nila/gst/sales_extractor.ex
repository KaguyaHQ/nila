defmodule Nila.Gst.SalesExtractor do
  @moduledoc """
  Per-page, one-invoice-per-page extraction for a sales-bills PDF.

  A month's outward invoices are dumped into one PDF (one invoice per page in
  the scanned packets sent to the auditor), so extraction runs
  `extraction_target: "per_page"` against the sales-invoice schema and returns
  one artifact per page that `Nila.Gst.Gstr1.normalize_invoice/1` consumes.

  The outward mirror of `Nila.Gst.PurchaseExtractor`: the implementation is
  selected via `Application.get_env(:nila, :sales_extractor,
  Nila.Gst.SalesExtractor.MistralOCR)`. Mistral OCR is the operational default;
  tests override it with the offline stub and LlamaExtract remains an explicit
  benchmark adapter.

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

  # Supported opts: :filename and an optional :on_progress callback receiving
  # coarse stages such as :rendering, :reading, :extracting.
end
