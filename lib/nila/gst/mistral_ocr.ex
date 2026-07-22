defmodule Nila.Gst.MistralOCR do
  @moduledoc false

  @model "mistral-ocr-4-0"
  @supported_content_types ~w(application/pdf image/jpeg image/png image/webp image/avif image/heic image/heif)

  def model, do: @model
  def provider, do: "mistral"

  def extract(kind, bytes, opts) when kind in [:purchase, :sales] and is_binary(bytes) do
    filename = Keyword.get(opts, :filename, default_filename(kind))
    content_type = Keyword.get(opts, :content_type, content_type(filename))
    on_progress = Keyword.get(opts, :on_progress, fn _stage -> :ok end)
    pages = Keyword.get(opts, :pages)

    with true <- content_type in @supported_content_types,
         :ok <- on_progress.(:reading),
         {:ok, response} <- request(kind, bytes, content_type, pages),
         :ok <- on_progress.(:extracting),
         {:ok, result} <- map_response(kind, response) do
      {:ok, result}
    else
      false -> {:error, {:unsupported_content_type, content_type}}
      {:error, reason, audit} -> {:error, reason, audit}
      {:error, reason} -> {:error, reason}
    end
  end

  def annotation_schema(kind) when kind in [:purchase, :sales] do
    invoice_properties = %{
      source_pages: %{
        type: "array",
        description:
          "All 1-based source page numbers belonging to this invoice, including continuation pages.",
        items: %{type: "integer", minimum: 1},
        minItems: 1
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
          "Copy the invoice-level CGST summary amount exactly. Never calculate or allocate it from item rows."
        ),
      printed_sgst:
        described_nullable(
          "number",
          "Copy the invoice-level SGST summary amount exactly. Never calculate or allocate it from item rows."
        ),
      printed_igst:
        described_nullable(
          "number",
          "Copy the invoice-level IGST summary amount exactly. Never calculate or allocate it from item rows."
        ),
      printed_total_tax:
        described_nullable(
          "number",
          "Copy the final printed total GST exactly; never calculate it from item rows."
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

    invoice_schema = strict_object(invoice_properties)

    strict_object(%{
      invoices: %{
        type: "array",
        description:
          "Every distinct GST invoice in the complete document. A multi-page invoice is one entry, never one entry per page.",
        items: invoice_schema
      }
    })
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

  def request_payload(kind, bytes, content_type, pages \\ nil) do
    %{
      model: @model,
      document: document(bytes, content_type),
      table_format: "markdown",
      include_blocks: true,
      confidence_scores_granularity: "word",
      document_annotation_format: %{
        type: "json_schema",
        json_schema: %{
          name: "nila_#{kind}_invoices",
          strict: true,
          schema: annotation_schema(kind)
        }
      },
      document_annotation_prompt: annotation_prompt(kind)
    }
    |> maybe_put_pages(pages)
  end

  def map_response(kind, %{body: body} = response) when is_binary(body) do
    audit = audit(response, body)

    with true <- response.status in 200..299,
         {:ok, decoded} <- Jason.decode(body),
         {:ok, annotation} <- decode_annotation(decoded["document_annotation"]),
         invoices when is_list(invoices) <- annotation["invoices"],
         pages when is_list(pages) <- decoded["pages"],
         artifacts when artifacts != [] <- artifacts(kind, invoices, pages) do
      {:ok,
       %{
         pages: artifacts,
         images: %{},
         audit:
           audit
           |> Map.put(:usage, decoded["usage_info"] || %{})
           |> Map.put(:source_page_count, length(pages))
       }}
    else
      false ->
        {:error, {:mistral_ocr_failed, response.status, decode_error_body(body)}, audit}

      {:error, %Jason.DecodeError{} = reason} ->
        {:error, {:invalid_mistral_response, reason}, audit}

      {:error, reason} ->
        {:error, reason, audit}

      nil ->
        {:error, :missing_document_annotation, audit}

      _ ->
        {:error, :no_invoices_extracted, audit}
    end
  end

  defp request(kind, bytes, content_type, pages) do
    payload = request_payload(kind, bytes, content_type, pages)

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

  defp artifacts(kind, invoices, ocr_pages) do
    pages_by_number =
      ocr_pages
      |> Enum.with_index(1)
      |> Map.new(fn {page, fallback} ->
        page_number = if is_integer(page["index"]), do: page["index"] + 1, else: fallback
        {page_number, page}
      end)

    page_markdown = Map.new(pages_by_number, fn {number, page} -> {number, page_text(page)} end)

    invoices
    |> Enum.with_index(1)
    |> Enum.map(fn {invoice, fallback_page} ->
      {source_pages, attribution} = resolve_source_pages(invoice, page_markdown)
      page = List.first(source_pages) || fallback_page

      confidence =
        %{"source_attribution" => attribution_confidence(attribution)}
        |> Map.merge(ocr_confidence(source_pages, pages_by_number))

      data =
        invoice
        |> Map.drop(["source_pages"])
        |> ensure_invoice_markers(kind)

      %{
        "kind" => artifact_kind(kind),
        "version" => 1,
        "page" => page,
        "source_pages" => source_pages,
        "source_attribution" => attribution,
        "image" => nil,
        "data" => data,
        "confidence" => confidence
      }
    end)
  end

  defp page_text(page) do
    table_text = Enum.map_join(page["tables"] || [], "\n", &(&1["content"] || ""))
    block_text = Enum.map_join(page["blocks"] || [], "\n", &(&1["content"] || ""))
    Enum.join([page["markdown"] || "", table_text, block_text], "\n")
  end

  defp resolve_source_pages(invoice, page_markdown) do
    annotated =
      invoice
      |> Map.get("source_pages", [])
      |> Enum.filter(&(is_integer(&1) and Map.has_key?(page_markdown, &1)))
      |> Enum.uniq()
      |> Enum.sort()

    scored =
      page_markdown
      |> Enum.map(fn {page, markdown} -> {page, evidence_score(invoice, markdown)} end)
      |> Enum.filter(fn {_page, score} -> score >= 5 end)
      |> Enum.sort_by(fn {page, score} -> {-score, page} end)

    candidates = Enum.map(scored, &elem(&1, 0))

    cond do
      annotated != [] and candidates == [] ->
        {annotated, %{"status" => "unverified", "candidate_pages" => []}}

      annotated != [] and Enum.any?(annotated, &(&1 in candidates)) ->
        {annotated, %{"status" => "verified", "candidate_pages" => candidates}}

      annotated != [] ->
        {candidates,
         %{
           "status" => "ambiguous",
           "annotated_pages" => annotated,
           "candidate_pages" => candidates
         }}

      length(candidates) == 1 ->
        {candidates, %{"status" => "verified", "candidate_pages" => candidates}}

      candidates != [] ->
        {candidates, %{"status" => "ambiguous", "candidate_pages" => candidates}}

      true ->
        {[], %{"status" => "unresolved", "candidate_pages" => []}}
    end
  end

  defp evidence_score(invoice, markdown) do
    haystack = searchable(markdown)
    invoice_number = searchable(invoice["invoice_number"])
    seller_gstin = searchable(get_in(invoice, ["seller", "gstin"]))
    buyer_gstin = searchable(get_in(invoice, ["buyer", "gstin"]))
    total = searchable_amount(invoice["printed_grand_total"])

    0
    |> add_score(invoice_number != "" and String.contains?(haystack, invoice_number), 10)
    |> add_score(seller_gstin != "" and String.contains?(haystack, seller_gstin), 2)
    |> add_score(buyer_gstin != "" and String.contains?(haystack, buyer_gstin), 1)
    |> add_score(total != "" and String.contains?(haystack, total), 4)
  end

  defp add_score(score, true, points), do: score + points
  defp add_score(score, false, _points), do: score

  defp searchable(nil), do: ""

  defp searchable(value),
    do: value |> to_string() |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "")

  defp searchable_amount(nil), do: ""

  defp searchable_amount(value) do
    value
    |> to_string()
    |> String.replace(~r/[^0-9]/, "")
    |> String.trim_leading("0")
  end

  defp ensure_invoice_markers(data, :purchase) do
    data
    |> Map.put("is_invoice", true)
    |> Map.put("continuation_of_previous", false)
  end

  defp ensure_invoice_markers(data, :sales), do: data

  defp attribution_confidence(%{"status" => "verified"}), do: 1.0
  defp attribution_confidence(_attribution), do: 0.0

  defp ocr_confidence(source_pages, pages_by_number) do
    scores =
      source_pages
      |> Enum.map(&get_in(pages_by_number, [&1, "confidence_scores"]))
      |> Enum.reject(&is_nil/1)

    minimums = Enum.map(scores, & &1["minimum_page_confidence_score"]) |> Enum.reject(&is_nil/1)
    averages = Enum.map(scores, & &1["average_page_confidence_score"]) |> Enum.reject(&is_nil/1)

    %{}
    |> maybe_put_score("ocr_minimum", minimums)
    |> maybe_put_score("ocr_average", averages)
  end

  defp maybe_put_score(confidence, _key, []), do: confidence
  defp maybe_put_score(confidence, key, scores), do: Map.put(confidence, key, Enum.min(scores))

  defp decode_annotation(annotation) when is_map(annotation), do: {:ok, annotation}
  defp decode_annotation(annotation) when is_binary(annotation), do: Jason.decode(annotation)
  defp decode_annotation(nil), do: {:error, :missing_document_annotation}
  defp decode_annotation(_annotation), do: {:error, :invalid_document_annotation}

  defp document(bytes, "application/pdf") do
    %{type: "document_url", document_url: data_uri(bytes, "application/pdf")}
  end

  defp document(bytes, content_type) do
    %{type: "image_url", image_url: data_uri(bytes, content_type)}
  end

  defp data_uri(bytes, content_type), do: "data:#{content_type};base64,#{Base.encode64(bytes)}"

  defp audit(response, raw_response) do
    base_audit()
    |> Map.put(:http_status, response.status)
    |> Map.put(:provider_request_id, request_id(response.headers))
    |> Map.put(:raw_response, raw_response)
  end

  defp base_audit do
    %{provider: provider(), model: model(), usage: %{}}
  end

  defp request_id(headers) do
    headers
    |> Map.get("x-request-id", [])
    |> List.first()
  end

  defp decode_error_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp annotation_prompt(:purchase) do
    "Extract every purchase invoice in the selected pages from first page to last. Return one array entry for every distinct invoice, even when uncertain. Assemble multi-page invoices into one entry and include every 1-based source page from the original document. Use null for unprinted fields. Preserve printed values exactly. taxable_value always means the post-discount value before GST, never list value or pre-discount subtotal. When a GST Slab, Tax Summary, Add-CGST/Add-SGST, CGST OUTWARD or SGST OUTWARD summary is printed, copy its taxable turnover and tax amounts exactly into the printed_* fields; never recalculate or redistribute those summary values across item rows. Read handwritten tax and total boxes as printed values too. Capture subtotal, product discount, final taxable turnover, CGST, SGST, IGST, additional charges, rounding and grand total separately. A GST/HSN summary may supply invoice totals but must never become another line item. Include every actual item row, but never turn subtotal, total or amount-in-words rows into line items."
  end

  defp annotation_prompt(:sales) do
    "Extract every sales invoice in the complete document from first page to last. Return one array entry for every distinct invoice, including cancelled invoices and uncertain invoices. Assemble multi-page invoices into one entry and include every 1-based source page. Use null for unprinted fields. Preserve printed values exactly. Include every actual item row, but never split stacked CGST/SGST sub-rows or totals into separate line items."
  end

  defp maybe_put_pages(payload, nil), do: payload
  defp maybe_put_pages(payload, pages), do: Map.put(payload, :pages, pages)

  defp artifact_kind(:purchase), do: "purchase_invoice_extraction"
  defp artifact_kind(:sales), do: "gstr1_sales_invoice_extraction"
  defp default_filename(:purchase), do: "purchase_bills.pdf"
  defp default_filename(:sales), do: "sales_bills.pdf"

  defp content_type(filename) do
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
