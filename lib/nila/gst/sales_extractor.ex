defmodule Nila.Gst.SalesExtractor do
  @moduledoc """
  Per-page, one-invoice-per-page extraction for a sales-bills PDF.

  A month's outward invoices are dumped into one PDF (one invoice per page in
  the scanned packets sent to the auditor), so extraction runs
  `extraction_target: "per_page"` against the sales-invoice schema and returns
  one artifact per page that `Nila.Gst.Gstr1.normalize_invoice/1` consumes.

  The outward mirror of `Nila.Gst.PurchaseExtractor`: the implementation is
  selected via `Application.get_env(:nila, :sales_extractor,
  Nila.Gst.SalesExtractor.Stub)` so tests and dev stay offline while prod hits
  LlamaExtract.

  A successful `extract/2` returns:

      {:ok, %{
        pages: [page_artifact],           # string-keyed maps for Gstr1
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
