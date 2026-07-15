defmodule Nila.Gst.PurchaseExtractor do
  @moduledoc """
  Per-page, multi-invoice extraction for a purchase-bills PDF.

  Distinct from `Nila.Documents.Extractor` (single-doc, purchase-order shape):
  a month's bills are many invoices dumped into one PDF, so extraction runs
  `extraction_target: "per_page"` against the purchase-invoice schema and
  returns one artifact per page (with `is_invoice` / `continuation_of_previous`
  flags) that `Nila.Gst.PurchaseBooks` assembles into invoices.

  The implementation is selected via `Application.get_env(:nila,
  :purchase_extractor, Nila.Gst.PurchaseExtractor.Stub)` so tests and dev stay
  offline while prod hits LlamaExtract.

  A successful `extract/2` returns:

      {:ok, %{
        pages: [page_artifact],           # string-keyed maps for PurchaseBooks
        images: %{"page_01.png" => bytes} # rendered page images, by basename
      }}

  Each `page_artifact` carries `"page"`, `"image"` (`"images/page_NN.png"`),
  `"data"` (the extracted fields), and `"confidence"`.
  """

  @callback extract(pdf_bytes :: binary(), opts :: keyword()) ::
              {:ok, %{pages: [map()], images: %{String.t() => binary()}}} | {:error, term()}

  # Supported opts: :filename and an optional :on_progress callback receiving
  # coarse stages such as :rendering, :reading, :extracting.
end
