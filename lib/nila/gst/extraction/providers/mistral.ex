defmodule Nila.Gst.Extraction.Providers.Mistral do
  @moduledoc false

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
    |> Keyword.merge(auth: {:bearer, api_key()}, retry: false, receive_timeout: receive_timeout())
    |> Keyword.merge(req_options())
  end

  @doc "The schema for one invoice extracted by the segmented text call."
  def invoice_schema(kind) when kind in [:purchase, :sales] do
    kind |> invoice_properties() |> strict_object()
  end

  defp invoice_properties(kind) do
    %{
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
        described_nullable("number", "Printed goods/services subtotal before any discount."),
      printed_discount_amount:
        described_nullable(
          "number",
          "Total product/trade discount as a positive amount; null when no discount is printed."
        ),
      printed_total_taxable:
        described_nullable(
          "number",
          "Copy the final taxable turnover printed in the invoice-level GST/tax summary after discount. Never calculate it from item rows."
        ),
      printed_cgst:
        described_nullable(
          "number",
          "A single CGST amount printed once for the whole invoice, in the totals area below the item table — for example a row reading \"Add: CGST 9%\" or \"Total CGST\". The CGST column inside the item table is not this. If the invoice prints no such row, return null."
        ),
      printed_sgst:
        described_nullable(
          "number",
          "A single SGST amount printed once for the whole invoice, in the totals area below the item table — for example a row reading \"Add: SGST 9%\" or \"Total SGST\". The SGST column inside the item table is not this. If the invoice prints no such row, return null."
        ),
      printed_igst:
        described_nullable(
          "number",
          "The invoice-level IGST summary amount, copied exactly. Null when the bill prints no such summary. Never derive it — not from item rows, not by subtracting other tax fields from a total."
        ),
      printed_total_tax:
        described_nullable(
          "number",
          "The combined total GST printed on the bill, copied exactly. Null when none is printed. Never derive it — not by summing item rows, not from the CGST/SGST/IGST fields."
        ),
      printed_additional_charges:
        described_nullable(
          "number",
          "Total non-tax line additions after GST, such as packing, freight or other charges."
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
      description: nullable("string"),
      hsn_sac: nullable("string"),
      quantity: nullable("number"),
      uom: nullable("string"),
      unit_price: nullable("number"),
      discount_rate: described_nullable("number", "Printed percentage discount for this item."),
      discount_amount:
        described_nullable("number", "Discount amount subtracted from this item's list value."),
      taxable_value: %{
        anyOf: [%{type: "number"}, %{type: "null"}],
        description:
          "Post-discount taxable value before GST. Never return the pre-discount list value here."
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
