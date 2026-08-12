defmodule Nila.Gst.Extraction.Providers.Mistral do
  @moduledoc false

  alias Nila.Gst.Extraction.MistralDocumentAdapter

  @model "mistral-ocr-4-0"
  @supported_content_types ~w(application/pdf image/jpeg image/png image/webp image/avif image/heic image/heif)

  def model, do: @model
  def provider, do: "mistral"

  @doc """
  Uploads a document once and returns the `:document` payload that references it.

  Inlining base64-encodes the document and caps it at roughly 37.5 MB against
  the API's 50 MB request limit. The segmented pipeline uploads larger packets
  once and passes the signed URL through transcription instead.

  The file is Mistral's for 24 hours unless deleted, so callers should invoke
  `delete/1` as soon as the read finishes.
  """
  def upload(bytes, filename) when is_binary(bytes) do
    with {:ok, %{"id" => file_id}} <- upload_file(bytes, filename),
         {:ok, %{"url" => url}} <- signed_url(file_id) do
      {:ok, %{file_id: file_id, document: %{type: "document_url", document_url: url}}}
    else
      {:ok, body} -> {:error, {:mistral_files_unexpected_response, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Best-effort removal of an uploaded document. Never raises."
  def delete(file_id) when is_binary(file_id) do
    case Req.delete(request_options(url: "/v1/files/#{file_id}")) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:mistral_files_delete_failed, status}}
      {:error, reason} -> {:error, {:mistral_files_delete_failed, reason}}
    end
  end

  defp upload_file(bytes, filename) do
    options =
      request_options(
        url: "/v1/files",
        form_multipart: [purpose: "ocr", file: {bytes, filename: filename}]
      )

    options |> Req.post() |> decode_files_response()
  end

  defp signed_url(file_id) do
    request_options(url: "/v1/files/#{file_id}/url", params: [expiry: 24])
    |> Req.get()
    |> decode_files_response()
  end

  defp decode_files_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    case body do
      body when is_map(body) -> {:ok, body}
      body when is_binary(body) -> Jason.decode(body)
      body -> {:error, {:mistral_files_unexpected_response, body}}
    end
  end

  defp decode_files_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:mistral_files_failed, status, decode_error_body(body)}}

  defp decode_files_response({:error, reason}),
    do: {:error, {:mistral_files_request_failed, reason}}

  defp request_options(options) do
    options
    |> Keyword.update!(:url, &url/1)
    |> Keyword.merge(
      adapter: MistralDocumentAdapter,
      auth: {:bearer, api_key()},
      retry: false,
      receive_timeout: receive_timeout()
    )
    |> Keyword.merge(req_options())
  end

  @doc "The schema for one invoice extracted by the segmented text call."
  def invoice_schema(kind) when kind in [:purchase, :sales] do
    kind |> invoice_properties() |> strict_object()
  end

  defp invoice_properties(kind) do
    properties = %{
      document_type: %{
        type: "string",
        enum: ["invoice", "credit_note", "debit_note"],
        description:
          "Classify the document itself from its title and charging table. Footer terms that merely mention credit or debit notes do not change an invoice's type."
      },
      invoice_number: %{type: "string"},
      invoice_date: %{type: "string"},
      seller: party_schema(kind == :purchase),
      buyer: party_schema(false),
      delivery_address: nullable("string"),
      line_items: %{
        type: "array",
        description:
          "One row per actual goods/services item. Exclude totals, HSN summaries, tax recapitulations and amount-in-words rows.",
        items: line_item_schema()
      },
      printed_subtotal_before_discount:
        described_nullable(
          "number",
          "Literal goods/services subtotal printed before any discount. Copy it regardless of whether it includes GST; this field does not imply a taxable or tax-exclusive basis."
        ),
      printed_discount_amount:
        described_nullable(
          "number",
          "Total product/trade discount as a positive amount; null when no discount is printed."
        ),
      printed_total_taxable:
        described_nullable(
          "number",
          "Copy only a final invoice-level taxable turnover aggregate that is itself printed after discount. A subtotal labelled tax-inclusive and individual tax-rate or slab-summary taxable rows are not this aggregate. Return null when no invoice-level aggregate is printed; never select, combine or calculate one from item or summary rows."
        ),
      printed_cgst:
        described_nullable(
          "number",
          "A single invoice-level CGST aggregate that is itself printed in a totals or tax-summary area rather than an individual item or tax-rate row — for example a row labelled Total CGST. Return null when no invoice-level aggregate is printed; never select, combine or calculate one from summary rows."
        ),
      printed_sgst:
        described_nullable(
          "number",
          "A single invoice-level SGST aggregate that is itself printed in a totals or tax-summary area rather than an individual item or tax-rate row — for example a row labelled Total SGST. Return null when no invoice-level aggregate is printed; never select, combine or calculate one from summary rows."
        ),
      printed_igst:
        described_nullable(
          "number",
          "A single invoice-level IGST aggregate that is itself printed in a totals or tax-summary area rather than an individual item or tax-rate row. Return null when no invoice-level aggregate is printed; never select, combine or calculate one from summary rows."
        ),
      printed_total_tax:
        described_nullable(
          "number",
          "The combined invoice-level total GST only when that aggregate is itself printed. Return null when none is printed; never derive it from item rows, tax-rate summaries or the CGST/SGST/IGST fields."
        ),
      printed_additional_charges:
        described_nullable(
          "number",
          "A single invoice-level addition only when the document explicitly places that amount after GST in the total calculation. Do not infer that freight, packing, handling or another charge is post-GST, and do not combine separate charges unless their aggregate is itself printed."
        ),
      printed_rounding_adjustment:
        described_nullable(
          "number",
          "Signed printed rounding adjustment; negative when subtracted from the total."
        ),
      printed_grand_total:
        described_nullable(
          "number",
          "Final printed amount payable after tax, charges and rounding."
        )
    }

    if kind == :sales do
      Map.merge(properties, %{
        recipient_registration: %{
          type: "string",
          enum: ["registered", "unregistered", "unknown"],
          description:
            "Whether the recipient is GST-registered. A printed GSTIN means registered. Use unregistered only when the document positively identifies an unregistered/consumer recipient; a missing or unreadable GSTIN alone means unknown."
        },
        place_of_supply:
          described_nullable(
            "string",
            "Printed place of supply as a state name or GST state code. Copy it exactly; null when the document does not print one."
          ),
        document_status: %{
          type: "string",
          enum: ["active", "cancelled", "amendment", "unknown"],
          description:
            "Whether this is an active original document, a cancelled document, an amendment, or unclear. Do not treat a cancellation footer policy as the document's status."
        },
        supply_type: %{
          type: "string",
          enum: ["taxable", "nil_rated", "exempt", "non_gst", "export", "sez", "unknown"],
          description:
            "The supply treatment stated by the document. Ordinary GST-charged domestic supplies are taxable. Preserve nil-rated, exempt, non-GST, export and SEZ distinctions; use unknown when unclear."
        }
      })
    else
      properties
    end
  end

  defp party_schema(include_address?) do
    properties = %{
      name: nullable("string"),
      gstin: nullable("string")
    }

    properties =
      if include_address?, do: Map.put(properties, :address, nullable("string")), else: properties

    strict_object(properties)
  end

  defp line_item_schema do
    strict_object(%{
      item_name:
        described_nullable(
          "string",
          "Primary printed product or service text in this item's name or description cell. Exclude supplementary notes or narrative from item_name; preserve them in description."
        ),
      description:
        described_nullable(
          "string",
          "Full printed line description, including supplementary narrative after the item name."
        ),
      hsn_sac: nullable("string"),
      quantity: nullable("number"),
      uom: nullable("string"),
      printed_unit_price:
        described_nullable(
          "number",
          "Unit rate printed for this line. Copy it regardless of whether prices include GST; do not multiply it by quantity."
        ),
      discount_rate: described_nullable("number", "Printed percentage discount for this item."),
      discount_amount:
        described_nullable("number", "Discount amount subtracted from this item's list value."),
      printed_line_amount:
        described_nullable(
          "number",
          "The main extended amount printed for this whole line, regardless of the vendor's heading. This is not a unit rate and not the gross total after separately printed tax. Copy it whether tax-inclusive or tax-exclusive; null when no line amount is printed."
        ),
      printed_line_total:
        described_nullable(
          "number",
          "The gross total printed for this same item row after separately shown tax, regardless of the vendor's heading. Do not copy an invoice subtotal, grand total or amount-in-words value."
        ),
      printed_taxable_value:
        described_nullable(
          "number",
          "A distinct source field that separately prints this line's taxable value before GST. Do not duplicate printed_line_amount into this field merely because the line amount is tax-exclusive; return null when no separate taxable-value field is printed."
        ),
      line_amount_tax_inclusion: %{
        type: "string",
        enum: ["inclusive", "exclusive", "unknown"],
        description:
          "Whether printed_line_amount includes GST, inferred from labels, table structure or visible same-row arithmetic. Labels apply only at their structural scope; invoice summaries, footer captions and amount-in-words labels do not determine line-amount inclusion. Use unknown when evidence is incomplete or conflicting."
      },
      cgst_rate: nullable("number"),
      cgst_amount: nullable("number"),
      sgst_rate: nullable("number"),
      sgst_amount: nullable("number"),
      igst_rate: nullable("number"),
      igst_amount: nullable("number")
    })
  end

  defp strict_object(properties) do
    %{
      type: "object",
      additionalProperties: false,
      properties: properties,
      required: properties |> Map.keys() |> Enum.map(&to_string/1)
    }
  end

  defp nullable(type), do: %{anyOf: [%{type: type}, %{type: "null"}]}

  defp described_nullable(type, description) do
    nullable(type) |> Map.put(:description, description)
  end

  @doc """
  A transcription-only `/v1/ocr` request.

  `/v1/ocr` can fuse two jobs — transcribe the pixels, then have a language model
  read the transcription and emit JSON. Only the second one has a per-call output
  budget, and that budget is what a dense multi-invoice request overruns. Asking
  for transcription alone therefore has no equivalent output-size ceiling,
  and it produces the artifact every later stage argues over: **one canonical
  text per physical page**. The interpretation half moves to
  `Nila.Gst.Extraction.Providers.MistralChat`, text in and JSON out, where it can
  be re-run offline against these bytes and scoped to a single invoice.
  """
  def transcription_payload(bytes, content_type, pages \\ nil, document \\ nil) do
    %{
      model: @model,
      document: document || document(bytes, content_type),
      table_format: "markdown",
      include_blocks: true,
      confidence_scores_granularity: "word"
    }
    |> maybe_put_pages(pages)
  end

  @doc "Transcription-only call returning `{:ok, %{status, headers, body}}`."
  def transcribe_raw(bytes, opts \\ []) when is_binary(bytes) do
    filename = Keyword.get(opts, :filename, "document.pdf")
    content_type = Keyword.get(opts, :content_type, content_type(filename))

    if content_type in @supported_content_types do
      bytes
      |> transcription_payload(
        content_type,
        Keyword.get(opts, :pages),
        Keyword.get(opts, :document)
      )
      |> post_ocr()
    else
      {:error, {:unsupported_content_type, content_type}}
    end
  end

  @doc "Cache key parts for a transcription: no prompt, no schema, so only the model shapes it."
  def transcription_fingerprint do
    %{model: @model, mode: "transcription"}
  end

  defp post_ocr(payload) do
    options =
      [
        url: url("/v1/ocr"),
        auth: {:bearer, api_key()},
        json: payload,
        adapter: MistralDocumentAdapter,
        decode_body: false,
        retry: false,
        receive_timeout: receive_timeout()
      ]
      |> Keyword.merge(req_options())

    case Req.post(options) do
      {:ok, %Req.Response{} = response} ->
        map_http_response(response)

      {:error, reason} ->
        {:error, {:mistral_ocr_request_failed, reason}, base_audit()}
    end
  end

  defp map_http_response(response) do
    {:ok,
     %{
       status: response.status,
       headers: response.headers,
       body: IO.iodata_to_binary(response.body)
     }}
  end

  defp document(bytes, "application/pdf") do
    %{type: "document_url", document_url: data_uri(bytes, "application/pdf")}
  end

  defp document(bytes, content_type) do
    %{type: "image_url", image_url: data_uri(bytes, content_type)}
  end

  defp data_uri(bytes, content_type), do: "data:#{content_type};base64,#{Base.encode64(bytes)}"

  defp base_audit do
    %{provider: provider(), model: model(), usage: %{}}
  end

  # `/v1/ocr` is fetched with `decode_body: false` and hands back a raw string;
  # the Files endpoints let Req decode, so an error body arrives already a map.
  defp decode_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_error_body(body), do: body

  defp maybe_put_pages(payload, nil), do: payload
  defp maybe_put_pages(payload, pages), do: Map.put(payload, :pages, pages)

  @doc "Content type inferred from a filename's extension."
  def content_type(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".pdf" -> "application/pdf"
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      ".avif" -> "image/avif"
      ".heic" -> "image/heic"
      ".heif" -> "image/heif"
      _ -> "application/octet-stream"
    end
  end

  defp config, do: Application.get_env(:nila, __MODULE__, [])
  defp url(path), do: (config()[:base_url] || "https://api.mistral.ai") <> path
  defp api_key, do: config()[:api_key]
  defp receive_timeout, do: config()[:receive_timeout] || 300_000
  defp req_options, do: config()[:req_options] || []
end
