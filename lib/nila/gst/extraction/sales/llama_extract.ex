defmodule Nila.Gst.Extraction.Sales.LlamaExtract do
  @moduledoc """
  Real `Nila.Gst.Extraction.Sales` backed by LlamaExtract v2, per-page.

  The outward mirror of `Nila.Gst.Extraction.Purchase.LlamaExtract`. Lifts the
  proven flow from `scripts/extract_sales.exs`: render each PDF page to a PNG
  with `pdftoppm`, upload the PDF for a `file_id`, submit a `per_page`
  extraction with the sales-invoice `data_schema` (line items authoritative;
  printed totals only for reconciliation), poll to completion, then reshape each
  page result into the artifact `Nila.Gst.Sales.Gstr1.normalize_invoice/1` consumes.

  Selected explicitly with `GST_OCR_PROVIDER=llama`; credentials alone never
  change the active provider.
  """
  @behaviour Nila.Gst.Extraction.Sales

  require Logger

  def provider, do: "llama"
  def model, do: version()

  @impl true
  def extract(pdf_bytes, opts) when is_binary(pdf_bytes) do
    filename = Keyword.get(opts, :filename, "sales_bills.pdf")
    on_progress = Keyword.get(opts, :on_progress, fn _stage -> :ok end)

    with :ok <- on_progress.(:rendering),
         {:ok, images} <- render_page_images(pdf_bytes),
         {:ok, file_id} <- upload(pdf_bytes, filename),
         {:ok, job_id} <- submit(file_id),
         :ok <- on_progress.(:reading),
         {:ok, body} <- poll(job_id, 1) do
      on_progress.(:extracting)

      case pages(body, images) do
        [] -> {:error, :no_pages_extracted}
        pages -> {:ok, %{pages: pages, images: images}}
      end
    end
  end

  # ── Page rendering ──────────────────────────────────────────────────────────

  defp render_page_images(pdf_bytes) do
    dir = Path.join(System.tmp_dir!(), "nila_sales_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    pdf_path = Path.join(dir, "source.pdf")

    try do
      File.write!(pdf_path, pdf_bytes)

      case System.cmd("pdftoppm", ["-png", "-r", "150", pdf_path, Path.join(dir, "page")],
             stderr_to_stdout: true
           ) do
        {_out, 0} -> {:ok, read_rendered(dir)}
        {out, status} -> {:error, {:pdftoppm_failed, status, out}}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp read_rendered(dir) do
    dir
    |> Path.join("page-*.png")
    |> Path.wildcard()
    |> Map.new(fn path ->
      [num] = Regex.run(~r/page-(\d+)\.png$/, path, capture: :all_but_first)
      padded = String.pad_leading(num, 2, "0")
      {"page_#{padded}.png", File.read!(path)}
    end)
  end

  # ── HTTP steps ──────────────────────────────────────────────────────────────

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
      params: params(project_id: project_id()),
      receive_timeout: receive_timeout(),
      json: %{
        file_input: file_id,
        configuration: %{
          tier: tier(),
          version: version(),
          extraction_target: "per_page",
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
      params: params(project_id: project_id(), expand: "extract_metadata"),
      receive_timeout: receive_timeout()
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"status" => "COMPLETED"} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: %{"status" => status} = body}}
      when status in ["FAILED", "CANCELLED", "ERROR"] ->
        {:error, {:extraction_failed, status, body}}

      {:ok, %Req.Response{status: 200, body: %{"status" => running}}} ->
        Logger.debug("sales_extract.poll job_id=#{job_id} attempt=#{attempt} status=#{running}")

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

  # ── Response mapping ────────────────────────────────────────────────────────

  @doc """
  Reshapes a COMPLETED per-page LlamaExtract response into the artifact list
  `Nila.Gst.Sales.Gstr1.normalize_invoice/1` consumes, attaching each page's rendered
  image basename. Pure.
  """
  def pages(body, images) when is_map(body) do
    body
    |> page_results()
    |> Enum.with_index(1)
    |> Enum.map(fn {page, index} ->
      page_no = page["page"] || index
      padded = page_no |> to_string() |> String.pad_leading(2, "0")
      basename = "page_#{padded}.png"

      %{
        "kind" => "gstr1_sales_invoice_extraction",
        "version" => 1,
        "page" => page_no,
        "image" => if(Map.has_key?(images, basename), do: "images/#{basename}"),
        "data" => page["data"] || page["extract_result"] || page["result"] || page,
        "confidence" => non_empty_map(page["confidence"]) || non_empty_map(page["field_metadata"])
      }
    end)
  end

  defp page_results(body) do
    cond do
      is_list(body["extract_result"]) ->
        body["extract_result"]

      is_list(body["result"]) ->
        body["result"]

      is_list(body["pages"]) ->
        body["pages"]

      is_list(get_in(body, ["extract_result", "pages"])) ->
        get_in(body, ["extract_result", "pages"])

      is_list(get_in(body, ["result", "pages"])) ->
        get_in(body, ["result", "pages"])

      true ->
        []
    end
  end

  defp non_empty_map(value) when is_map(value) and map_size(value) > 0, do: value
  defp non_empty_map(_), do: nil

  # ── Config ──────────────────────────────────────────────────────────────────

  defp config, do: Application.get_env(:nila, __MODULE__, [])
  defp url(path), do: (config()[:base_url] || "https://api.cloud.llamaindex.ai") <> path
  defp api_key, do: config()[:api_key]
  defp project_id, do: config()[:project_id]
  defp tier, do: config()[:tier] || "agentic"
  defp version, do: config()[:version] || "latest"
  defp receive_timeout, do: config()[:receive_timeout] || 60_000
  defp poll_interval_ms, do: config()[:poll_interval_ms] || 3_000
  defp max_polls, do: config()[:max_polls] || 200

  defp params(pairs), do: Enum.reject(pairs, fn {_key, value} -> is_nil(value) end)

  # ── Extraction schema (validated in scripts/extract_sales.exs) ──────────────

  @gstin_desc "15-character Indian GSTIN. First 2 digits are state code; next 10 PAN-like characters; 15th is checksum. Preserve exactly when printed."
  @amount_desc "Number only. Strip currency symbols and thousands separators. Use the line item table as truth."
  @rate_desc "GST rate as plain percentage number, e.g. 9 for CGST 9%. Use null when not applicable."

  defp schema do
    %{
      type: "object",
      properties: %{
        invoice_number: %{
          type: "string",
          description:
            "Invoice number exactly as printed, including financial-year suffix, e.g. 20/2026-27"
        },
        invoice_date: %{
          type: "string",
          description: "Invoice date exactly as printed, usually DD.MM.YYYY"
        },
        seller: %{
          type: "object",
          description: "The supplier/seller issuing the tax invoice",
          properties: %{
            name: %{type: "string", description: "Seller legal/trade name"},
            gstin: %{type: "string", description: @gstin_desc}
          }
        },
        buyer: %{
          type: "object",
          description: "The recipient/buyer billed on the invoice",
          properties: %{
            name: %{type: "string", description: "Buyer legal/trade name"},
            gstin: %{type: "string", description: @gstin_desc}
          }
        },
        line_items: %{
          type: "array",
          description:
            "One entry per S.No in the item table. The Tax Type column may stack CGST and SGST as two printed sub-rows within a single item's row — these are two tax components of the SAME line item, never two separate items. Never emit separate CGST-only and SGST-only entries; an intra-state line carries both cgst and sgst fields. Line items are authoritative for taxable value and tax; printed totals may be wrong.",
          items: %{
            type: "object",
            properties: %{
              description: %{type: "string", description: "Printed item/service description"},
              hsn_sac: %{
                type: "string",
                description:
                  "Printed HSN/SAC code, usually 6 to 8 digits. Preserve full printed code."
              },
              quantity: %{
                type: "number",
                description: "Quantity from the Qty column for this S.No"
              },
              uom: %{type: "string", description: "Printed unit of measure"},
              unit_price: %{type: "number", description: @amount_desc},
              taxable_value: %{
                type: "number",
                description: "Taxable value for this line before GST. " <> @amount_desc
              },
              cgst_rate: %{anyOf: [%{type: "number"}, %{type: "null"}], description: @rate_desc},
              cgst_amount: %{
                anyOf: [%{type: "number"}, %{type: "null"}],
                description: @amount_desc
              },
              sgst_rate: %{anyOf: [%{type: "number"}, %{type: "null"}], description: @rate_desc},
              sgst_amount: %{
                anyOf: [%{type: "number"}, %{type: "null"}],
                description: @amount_desc
              },
              igst_rate: %{anyOf: [%{type: "number"}, %{type: "null"}], description: @rate_desc},
              igst_amount: %{
                anyOf: [%{type: "number"}, %{type: "null"}],
                description: @amount_desc
              }
            }
          }
        },
        printed_total_taxable: %{
          type: "number",
          description:
            "Printed taxable total, extracted only for reconciliation checks. Do not use as truth if line sums differ. " <>
              @amount_desc
        },
        printed_total_tax: %{
          type: "number",
          description:
            "Printed total GST amount, extracted only for reconciliation checks. Do not use as truth if line sums differ. " <>
              @amount_desc
        },
        printed_grand_total: %{
          type: "number",
          description:
            "Printed grand total including GST, extracted only for reconciliation checks. Line items are authoritative and this total may be wrong. " <>
              @amount_desc
        }
      },
      required: ["invoice_number", "invoice_date", "seller", "buyer", "line_items"]
    }
  end
end
