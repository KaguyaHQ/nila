defmodule Nila.Gst.Extraction.Sales do
  @moduledoc """
  Sales-invoice extraction for a sales-bills PDF.

  Extraction returns one artifact per discovered invoice. Page attribution is
  evidence, not identity: one invoice may span pages and multiple invoice
  artifacts may refer to the same page. `Nila.Gst.Intake.DumpWorker` assigns
  stable source identity from dump ID plus artifact ordinal before persistence.

  The outward mirror of `Nila.Gst.Extraction.Purchase`: the implementation is
  selected via `Application.get_env(:nila, :sales_extractor,
  Nila.Gst.Extraction.Sales.Extractor)`. The production extractor segments rendered
  pages and reads each invoice with the configured model. `input: :text` explicitly
  selects native text for known digital PDFs, retaining vision for empty pages and
  invoice groups with scanned continuations. The default remains `:vision` until
  native-text intake has been validated on complete client months. Tests may override
  the full pipeline.

  A successful `extract/2` returns:

      {:ok, %{
        pages: [invoice_artifact],        # string-keyed maps for Gstr1
        images: %{"page_01.png" => bytes} # rendered page images, by basename
      }}

  Each `invoice_artifact` carries `"page"`, `"image"` (`"images/page_NN.png"`),
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

  # Supported opts: :filename, :input (:vision or :text), an optional :on_progress callback receiving
  # extraction progress events, and :per_call for extractors that declare
  # `per_call?/0`.
end
