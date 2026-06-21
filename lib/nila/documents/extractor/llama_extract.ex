defmodule Nila.Documents.Extractor.LlamaExtract do
  @moduledoc """
  Real `Nila.Documents.Extractor` backed by the LlamaExtract v2 REST API.

  Flow (proven in `scripts/extract_po.exs`): upload the PDF for a `file_id`,
  submit a per-doc extraction job with our purchase-order `data_schema`, poll
  until it completes, then reshape the result + per-field confidence into the
  canonical artifact map the rest of the pipeline already consumes.

  Activated only when `LLAMA_CLOUD_API_KEY` is present (see `config/runtime.exs`);
  otherwise the worker stays on `Nila.Documents.Extractor.Stub`.
  """
  @behaviour Nila.Documents.Extractor

  require Logger

  @impl true
  def extract(pdf_bytes, opts) when is_binary(pdf_bytes) do
    filename = Keyword.get(opts, :filename, "purchase_order.pdf")
    on_progress = Keyword.get(opts, :on_progress, fn _stage -> :ok end)
    started_at = System.monotonic_time()

    with {:ok, file_id} <-
           timed("llama_extract.upload", fn -> upload(pdf_bytes, filename) end,
             filename: filename,
             byte_size: byte_size(pdf_bytes)
           ),
         {:ok, job_id} <-
           timed("llama_extract.submit", fn -> submit(file_id) end, filename: filename),
         :ok <- on_progress.(:reading),
         {:ok, body} <-
           timed("llama_extract.poll", fn -> poll(job_id, 1) end,
             filename: filename,
             job_id: job_id
           ) do
      on_progress.(:extracting)

      Logger.info(
        "llama_extract.complete filename=#{inspect(filename)} duration_ms=#{elapsed_ms(started_at)}"
      )

      {:ok, map_result(body)}
    else
      {:error, reason} = error ->
        Logger.error(
          "LlamaExtract extraction failed: #{inspect(reason)} filename=#{inspect(filename)} duration_ms=#{elapsed_ms(started_at)}"
        )

        error
    end
  end

  # ── HTTP steps ────────────────────────────────────────────────────────────

  defp upload(bytes, filename) do
    Req.post(url("/api/v1/beta/files"),
      auth: {:bearer, api_key()},
      receive_timeout: receive_timeout(),
      form_multipart: [
        file: {bytes, filename: filename, content_type: "application/pdf"},
        purpose: "extract"
      ]
    )
    |> case do
      {:ok, %Req.Response{status: status, body: %{"id" => id}}} when status in 200..299 ->
        {:ok, id}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:upload_failed, status, body}}

      {:error, reason} ->
        {:error, {:upload_error, reason}}
    end
  end

  defp submit(file_id) do
    Req.post(url("/api/v2/extract"),
      auth: {:bearer, api_key()},
      params: [project_id: project_id()],
      receive_timeout: receive_timeout(),
      json: %{
        file_input: file_id,
        configuration: %{
          tier: tier(),
          version: version(),
          extraction_target: "per_doc",
          data_schema: schema(),
          cite_sources: true,
          confidence_scores: true
        }
      }
    )
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body["id"] || body["job_id"]}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:submit_failed, status, body}}

      {:error, reason} ->
        {:error, {:submit_error, reason}}
    end
  end

  defp poll(job_id, attempt) do
    Req.get(url("/api/v2/extract/#{job_id}"),
      auth: {:bearer, api_key()},
      params: [project_id: project_id(), expand: "extract_metadata"],
      receive_timeout: receive_timeout()
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"status" => "COMPLETED"} = body}} ->
        Logger.info(
          "llama_extract.poll_attempt job_id=#{job_id} attempt=#{attempt} status=COMPLETED"
        )

        {:ok, body}

      {:ok, %Req.Response{status: 200, body: %{"status" => status} = body}}
      when status in ["FAILED", "CANCELLED", "ERROR"] ->
        Logger.info(
          "llama_extract.poll_attempt job_id=#{job_id} attempt=#{attempt} status=#{status}"
        )

        {:error, {:extraction_failed, status, body}}

      {:ok, %Req.Response{status: 200, body: %{"status" => running}}} ->
        Logger.debug(
          "llama_extract.poll_attempt job_id=#{job_id} attempt=#{attempt} status=#{running}"
        )

        if attempt >= max_polls() do
          {:error, :extraction_timeout}
        else
          Process.sleep(poll_interval_ms())
          poll(job_id, attempt + 1)
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:poll_failed, status, body}}

      {:error, reason} ->
        {:error, {:poll_error, reason}}
    end
  end

  # ── Pure response mapping ───────────────────────────────────────────────────

  @doc """
  Reshape a COMPLETED LlamaExtract response body into the canonical
  `purchase_order_extraction` artifact map. Pure — tested against a captured
  real response. `supplier` is the PO "Order to" (us); `bill_to` is the
  "Payer" (the customer we invoice). Do not swap them.
  """
  def map_result(body) when is_map(body) do
    data = body["extract_result"] || body["result"] || %{}
    field_meta = get_in(body, ["extract_metadata", "field_metadata", "document_metadata"]) || %{}

    supplier = data["supplier"] || %{}
    buyer = data["bill_to"] || %{}
    ship_to = data["ship_to"] || %{}
    line_items = Enum.map(data["line_items"] || [], &map_line/1)

    canonical = %{
      "po_number" => data["po_number"],
      "po_date" => data["po_date"],
      "payment_terms" => data["payment_terms"],
      "place_of_supply" => data["place_of_supply"],
      "supplier_name" => supplier["name"],
      "supplier_gstin" => supplier["gstin"],
      "supplier_address" => supplier["address"],
      "buyer_name" => buyer["name"],
      "buyer_gstin" => buyer["gstin"],
      "buyer_address" => buyer["address"],
      "ship_to_name" => ship_to["name"],
      "ship_to_address" => ship_to["address"],
      "line_items" => line_items,
      "subtotal" => to_money(data["total_net_amount"]),
      "tax_total" => sum_tax(data),
      "grand_total" => to_money(data["total_gross_amount"])
    }

    confidence = build_confidence(field_meta)
    parse_job_id = body["parse_job_id"] || get_in(body, ["extract_metadata", "parse_job_id"])

    %{
      "kind" => "purchase_order_extraction",
      "version" => 1,
      "data" => canonical,
      "confidence" => confidence,
      "exceptions" => exceptions(confidence),
      "_source" => %{"parse_job_id" => parse_job_id}
    }
  end

  defp map_line(li) do
    %{
      "description" => li["description"],
      "hsn_sac" => li["hsn_sac"],
      "quantity" => li["quantity"],
      "unit" => li["uom"],
      "unit_price" => to_money(li["unit_price"]),
      "taxable" => to_money(li["net_amount"]),
      "cgst_rate" => li["cgst_rate"],
      "cgst_amount" => to_money(li["cgst_amount"]),
      "sgst_rate" => li["sgst_rate"],
      "sgst_amount" => to_money(li["sgst_amount"]),
      "igst_rate" => li["igst_rate"],
      "igst_amount" => to_money(li["igst_amount"]),
      # Derived, not extracted: a single blended rate and the line gross
      # (taxable + GST), computed so the line total always reconciles. Consumed
      # by the review UI and the invoice draft builder.
      "tax_rate" => line_tax_rate(li),
      "amount" => line_amount(li)
    }
  end

  # The fields whose accuracy decides invoice compliance. Confidence below
  # @confidence_threshold on any of these is surfaced as an exception in the UI.
  @confidence_threshold 0.90

  defp build_confidence(field_meta) do
    first_line = field_meta |> Map.get("line_items", []) |> List.wrap() |> List.first() || %{}

    %{
      "po_number" => conf(field_meta["po_number"]),
      "buyer_gstin" => conf(get_in(field_meta, ["bill_to", "gstin"])),
      "supplier_gstin" => conf(get_in(field_meta, ["supplier", "gstin"])),
      "grand_total" => conf(field_meta["total_gross_amount"]),
      "hsn_sac" => conf(first_line["hsn_sac"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp conf(%{"confidence" => value}) when is_number(value), do: value
  defp conf(_), do: nil

  defp exceptions(confidence) do
    confidence
    |> Enum.filter(fn {_field, value} -> value < @confidence_threshold end)
    |> Enum.map(fn {field, _value} -> field end)
    |> Enum.sort()
  end

  defp sum_tax(data) do
    total =
      num(data["total_cgst_amount"]) + num(data["total_sgst_amount"]) +
        num(data["total_igst_amount"])

    to_money(total)
  end

  defp line_tax_rate(li) do
    if num(li["igst_rate"]) > 0 do
      to_string(li["igst_rate"])
    else
      to_string(num(li["cgst_rate"]) + num(li["sgst_rate"]))
    end
  end

  defp line_amount(li) do
    total =
      num(li["net_amount"]) + num(li["cgst_amount"]) + num(li["sgst_amount"]) +
        num(li["igst_amount"])

    to_money(total)
  end

  defp to_money(nil), do: nil
  defp to_money(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp to_money(s) when is_binary(s), do: s

  defp num(nil), do: 0
  defp num(n) when is_number(n), do: n

  # Money/rate fields are schema-typed number|null, so anything else means the
  # API broke its contract. Coerce to 0 but make it loud — a silently-zeroed tax
  # value would corrupt the total with no trace.
  defp num(other) do
    Logger.warning("llama_extract.num coerced non-numeric value to 0: #{inspect(other)}")
    0
  end

  # ── Config ──────────────────────────────────────────────────────────────────

  defp config, do: Application.get_env(:nila, __MODULE__, [])
  defp url(path), do: (config()[:base_url] || "https://api.cloud.llamaindex.ai") <> path
  defp api_key, do: config()[:api_key]
  defp project_id, do: config()[:project_id]
  defp tier, do: config()[:tier] || "agentic"
  defp version, do: config()[:version] || "latest"
  defp receive_timeout, do: config()[:receive_timeout] || 60_000
  defp poll_interval_ms, do: config()[:poll_interval_ms] || 3_000
  defp max_polls, do: config()[:max_polls] || 40

  defp timed(label, fun, metadata) do
    started_at = System.monotonic_time()
    result = fun.()

    Logger.info(
      "#{label} #{format_metadata(metadata)} duration_ms=#{elapsed_ms(started_at)} result=#{result_tag(result)}"
    )

    result
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp result_tag({:ok, value}) when is_binary(value), do: "ok:#{value}"
  defp result_tag({:ok, _}), do: "ok"
  defp result_tag({:error, reason}), do: "error:#{inspect(reason)}"

  defp format_metadata(metadata) do
    metadata
    |> Enum.map(fn {key, value} -> "#{key}=#{inspect(value)}" end)
    |> Enum.join(" ")
  end

  # ── Extraction schema (validated in scripts/extract_po.exs) ─────────────────

  @gstin_desc "15-char Indian GSTIN, e.g. 33AEWPH4158J1Z3; first 2 digits are the state code"
  @amount_desc "Numeric only, strip currency symbol and thousands separators, e.g. 49420.00"
  @rate_desc "GST rate as a plain percentage number, e.g. 9 for 9%"

  defp schema do
    %{
      type: "object",
      properties: %{
        po_number: %{
          type: "string",
          description: "Purchase order number, digits only, e.g. 4700329424"
        },
        po_date: %{type: "string", description: "PO date of issue, format DD.MM.YYYY"},
        supplier: %{
          type: "object",
          description: "The 'Order to' vendor: the seller raising the invoice",
          properties: %{
            name: %{type: "string", description: "Vendor legal name"},
            address: %{type: "string", description: "Full postal address as one line"},
            gstin: %{type: "string", description: @gstin_desc}
          }
        },
        bill_to: %{
          type: "object",
          description: "The 'Payer address': becomes the invoice Bill To party",
          properties: %{
            name: %{type: "string", description: "Payer legal name"},
            address: %{type: "string", description: "Full postal address as one line"},
            gstin: %{type: "string", description: @gstin_desc}
          }
        },
        ship_to: %{
          type: "object",
          description: "The 'Deliver to' consignee: becomes the invoice Delivery Address",
          properties: %{
            name: %{type: "string"},
            address: %{type: "string", description: "Full delivery address as one line"}
          }
        },
        place_of_supply: %{type: "string", description: "State name and/or GST state code"},
        payment_terms: %{type: "string", description: "Verbatim payment terms text"},
        line_items: %{
          type: "array",
          description: "One entry per line in the item table",
          items: %{
            type: "object",
            properties: %{
              description: %{type: "string", description: "Product/service description"},
              hsn_sac: %{
                type: "string",
                description: "HSN or SAC code, 6 to 8 digits, e.g. 998719"
              },
              quantity: %{type: "number"},
              uom: %{type: "string", description: "Unit of measure, e.g. EA"},
              unit_price: %{type: "number", description: @amount_desc},
              net_amount: %{
                type: "number",
                description: "Taxable value before GST. " <> @amount_desc
              },
              cgst_rate: %{type: "number", description: @rate_desc},
              cgst_amount: %{type: "number", description: @amount_desc},
              sgst_rate: %{type: "number", description: @rate_desc},
              sgst_amount: %{type: "number", description: @amount_desc},
              igst_rate: %{anyOf: [%{type: "number"}, %{type: "null"}], description: @rate_desc},
              igst_amount: %{
                anyOf: [%{type: "number"}, %{type: "null"}],
                description: @amount_desc
              }
            }
          }
        },
        total_net_amount: %{type: "number", description: "Total taxable value. " <> @amount_desc},
        total_cgst_amount: %{type: "number", description: @amount_desc},
        total_sgst_amount: %{type: "number", description: @amount_desc},
        total_igst_amount: %{
          anyOf: [%{type: "number"}, %{type: "null"}],
          description: @amount_desc
        },
        total_gross_amount: %{
          type: "number",
          description: "Grand total incl. tax. " <> @amount_desc
        }
      }
    }
  end
end
