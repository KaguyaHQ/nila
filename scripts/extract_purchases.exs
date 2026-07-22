Code.require_file(Path.join(__DIR__, "gstr1_eval_lib.exs"))

defmodule PurchaseExtractScript do
  def run(args) do
    opts = parse_args(args)
    File.mkdir_p!(opts.pages_dir)
    File.mkdir_p!(opts.images_dir)

    api_key =
      System.get_env("LLAMA_CLOUD_API_KEY") ||
        get_in(Application.get_env(:nila, Nila.Gst.Extraction.Providers.Llama, []), [:api_key])

    if is_nil(api_key) or api_key == "" do
      Mix.raise("LLAMA_CLOUD_API_KEY is required to run extraction")
    end

    config = %{
      api_key: api_key,
      base_url: System.get_env("LLAMA_BASE_URL") || "https://api.cloud.llamaindex.ai",
      project_id: System.get_env("LLAMA_PROJECT_ID"),
      tier: System.get_env("LLAMA_TIER") || "agentic",
      version: System.get_env("LLAMA_VERSION") || "latest",
      receive_timeout: System.get_env("LLAMA_RECEIVE_TIMEOUT", "60000") |> String.to_integer(),
      poll_interval_ms: System.get_env("LLAMA_POLL_INTERVAL_MS", "3000") |> String.to_integer(),
      max_polls: System.get_env("LLAMA_MAX_POLLS", "200") |> String.to_integer()
    }

    render_page_images(opts.pdf_path, opts.images_dir)

    pdf_bytes = File.read!(opts.pdf_path)
    filename = Path.basename(opts.pdf_path)

    IO.puts("uploading #{opts.pdf_path}")
    file_id = upload(pdf_bytes, filename, config)
    IO.puts("uploaded #{file_id}; submitting per_page extraction")
    job_id = submit(file_id, config)
    IO.puts("submitted #{job_id}; polling")
    body = poll(job_id, config)
    Gstr1Eval.write_json!(Path.join(opts.out_dir, "llama_extract_response.json"), body)

    pages = extract_pages(body)

    if pages == [] do
      Mix.raise(
        "completed extraction did not contain recognizable per-page results; raw response written to #{Path.join(opts.out_dir, "llama_extract_response.json")}"
      )
    end

    pages
    |> Enum.with_index(1)
    |> Enum.each(fn {page, index} ->
      page_no = page["page"] || index
      image = image_for_page(opts.images_dir, page_no)

      artifact = %{
        "kind" => "purchase_invoice_extraction",
        "version" => 1,
        "page" => page_no,
        "image" => image && Path.join("images", image),
        "data" => page["data"] || page["extract_result"] || page["result"] || page,
        "confidence" =>
          non_empty_map(page["confidence"]) || non_empty_map(page["field_metadata"]),
        "_raw" => page
      }

      Gstr1Eval.write_json!(
        Path.join(opts.pages_dir, "page_#{String.pad_leading(to_string(index), 2, "0")}.json"),
        artifact
      )
    end)

    IO.puts("wrote #{length(pages)} page artifacts to #{opts.pages_dir}")
  end

  defp parse_args(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args, strict: [pdf: :string, out_dir: :string])

    pdf_path = Path.expand(opts[:pdf] || Mix.raise("--pdf is required"))
    base = pdf_path |> Path.basename() |> Path.rootname() |> slugify()
    out_dir = Path.expand(opts[:out_dir] || Path.expand("../tmp/purchase/#{base}", __DIR__))

    %{
      pdf_path: pdf_path,
      out_dir: out_dir,
      pages_dir: Path.join(out_dir, "pages"),
      images_dir: Path.join(out_dir, "images")
    }
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp render_page_images(pdf_path, images_dir) do
    existing = images_dir |> Path.join("page_*.png") |> Path.wildcard()

    if existing == [] do
      IO.puts("rendering page images to #{images_dir}")

      {_out, 0} =
        System.cmd("pdftoppm", ["-png", "-r", "150", pdf_path, Path.join(images_dir, "page")])

      images_dir
      |> Path.join("page-*.png")
      |> Path.wildcard()
      |> Enum.each(fn path ->
        [num] = Regex.run(~r/page-(\d+)\.png$/, path, capture: :all_but_first)
        padded = String.pad_leading(num, 2, "0")
        File.rename!(path, Path.join(images_dir, "page_#{padded}.png"))
      end)
    else
      IO.puts("page images already present (#{length(existing)}), skipping render")
    end
  end

  defp image_for_page(images_dir, page_no) do
    padded = page_no |> to_string() |> String.pad_leading(2, "0")
    name = "page_#{padded}.png"
    if File.exists?(Path.join(images_dir, name)), do: name
  end

  defp upload(bytes, filename, config) do
    Req.post(config.base_url <> "/api/v1/beta/files",
      auth: {:bearer, config.api_key},
      receive_timeout: config.receive_timeout,
      form_multipart: [
        file: {bytes, filename: filename, content_type: "application/pdf"},
        purpose: "extract"
      ]
    )
    |> case do
      {:ok, %Req.Response{status: status, body: %{"id" => id}}} when status in 200..299 ->
        id

      {:ok, %Req.Response{status: status, body: body}} ->
        Mix.raise("upload failed #{status}: #{inspect(body)}")

      {:error, reason} ->
        Mix.raise("upload error: #{inspect(reason)}")
    end
  end

  defp submit(file_id, config) do
    Req.post(config.base_url <> "/api/v2/extract",
      auth: {:bearer, config.api_key},
      params: Enum.reject([project_id: config.project_id], fn {_key, value} -> is_nil(value) end),
      receive_timeout: config.receive_timeout,
      json: %{
        file_input: file_id,
        configuration: %{
          tier: config.tier,
          version: config.version,
          extraction_target: "per_page",
          data_schema: purchase_schema(),
          cite_sources: true,
          confidence_scores: true
        }
      }
    )
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body["id"] || body["job_id"]

      {:ok, %Req.Response{status: status, body: body}} ->
        Mix.raise("submit failed #{status}: #{inspect(body)}")

      {:error, reason} ->
        Mix.raise("submit error: #{inspect(reason)}")
    end
  end

  defp poll(job_id, config), do: poll(job_id, config, 1)

  defp poll(job_id, config, attempt) do
    Req.get(config.base_url <> "/api/v2/extract/#{job_id}",
      auth: {:bearer, config.api_key},
      params:
        Enum.reject([project_id: config.project_id, expand: "extract_metadata"], fn {_key, value} ->
          is_nil(value)
        end),
      receive_timeout: config.receive_timeout
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"status" => "COMPLETED"} = body}} ->
        body

      {:ok, %Req.Response{status: 200, body: %{"status" => status} = body}}
      when status in ["FAILED", "CANCELLED", "ERROR"] ->
        Mix.raise("extraction failed #{status}: #{inspect(body)}")

      {:ok, %Req.Response{status: 200, body: %{"status" => status}}} ->
        IO.puts("poll #{attempt}/#{config.max_polls}: #{status}")

        if attempt >= config.max_polls do
          Mix.raise("extraction timeout")
        else
          Process.sleep(config.poll_interval_ms)
          poll(job_id, config, attempt + 1)
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Mix.raise("poll failed #{status}: #{inspect(body)}")

      {:error, reason} ->
        Mix.raise("poll error: #{inspect(reason)}")
    end
  end

  defp non_empty_map(value) when is_map(value) and map_size(value) > 0, do: value
  defp non_empty_map(_), do: nil

  defp extract_pages(body) do
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

  defp purchase_schema do
    gstin_desc =
      "15-character Indian GSTIN. First 2 digits are state code; next 10 PAN-like characters; 15th is checksum. Preserve exactly when printed."

    amount_desc =
      "Number only. Strip currency symbols and thousands separators. Use the line item table as truth."

    rate_desc =
      "GST rate as plain percentage number, e.g. 9 for CGST 9%. Use null when not applicable."

    %{
      type: "object",
      properties: %{
        is_invoice: %{
          type: "boolean",
          description:
            "true when this page is a tax invoice or bill of supply. false for continuation pages, delivery challans, payment receipts, blank pages, or annexures that carry no invoice header of their own."
        },
        continuation_of_previous: %{
          type: "boolean",
          description:
            "true when this page continues an invoice that started on an earlier page (no fresh invoice number/header on this page)."
        },
        invoice_number: %{
          type: "string",
          description:
            "Invoice number exactly as printed, including any financial-year suffix, e.g. 20/2026-27"
        },
        invoice_date: %{
          type: "string",
          description: "Invoice date exactly as printed, usually DD.MM.YYYY or DD/MM/YYYY"
        },
        seller: %{
          type: "object",
          description: "The supplier/vendor issuing this purchase bill",
          properties: %{
            name: %{type: "string", description: "Vendor legal/trade name as printed"},
            gstin: %{type: "string", description: gstin_desc},
            address: %{type: "string", description: "Vendor address as printed"},
            state: %{type: "string", description: "Vendor state name or code if printed"}
          }
        },
        buyer: %{
          type: "object",
          description: "The recipient/buyer billed on the invoice (our business)",
          properties: %{
            name: %{type: "string", description: "Buyer legal/trade name"},
            gstin: %{type: "string", description: gstin_desc},
            address: %{type: "string", description: "Billing address as printed"}
          }
        },
        delivery_address: %{
          anyOf: [%{type: "string"}, %{type: "null"}],
          description:
            "Ship-to / delivery / consignee address when printed separately from the billing address. Preserve exactly. Null when not printed."
        },
        line_items: %{
          type: "array",
          description:
            "One entry per S.No in the GOODS/SERVICES item table ONLY. NEVER include rows from an HSN-wise tax summary block, GST slab summary, or tax recapitulation table — those repeat the same amounts as reconciliation totals, and including them double-counts the invoice; report them via the printed_total fields instead. The Tax Type column may stack CGST and SGST as two printed sub-rows within a single item's row — these are two tax components of the SAME line item, never two separate items. Never emit separate CGST-only and SGST-only entries; an intra-state line carries both cgst and sgst fields. taxable_value is the value BEFORE GST but AFTER any discount; when a discount row follows the items, the post-discount turnover is the true taxable, never the pre-discount sub-total. If a column is tax-INCLUSIVE (often headed Amount or Value incl. GST), do not report it as taxable_value. When per-line tax columns are absent but a tax summary box prints CGST/SGST/IGST amounts (e.g. 'Add CGST 477.00'), attach those amounts to the lines — never report tax as zero when the invoice plainly charges GST.",
          items: %{
            type: "object",
            properties: %{
              description: %{type: "string", description: "Printed item/service description"},
              hsn_sac: %{
                type: "string",
                description:
                  "Printed HSN/SAC code, usually 4 to 8 digits. Preserve full printed code."
              },
              quantity: %{
                type: "number",
                description: "Quantity from the Qty column for this S.No"
              },
              uom: %{type: "string", description: "Printed unit of measure"},
              unit_price: %{type: "number", description: amount_desc},
              taxable_value: %{
                type: "number",
                description: "Taxable value for this line before GST. " <> amount_desc
              },
              cgst_rate: %{anyOf: [%{type: "number"}, %{type: "null"}], description: rate_desc},
              cgst_amount: %{
                anyOf: [%{type: "number"}, %{type: "null"}],
                description: amount_desc
              },
              sgst_rate: %{anyOf: [%{type: "number"}, %{type: "null"}], description: rate_desc},
              sgst_amount: %{
                anyOf: [%{type: "number"}, %{type: "null"}],
                description: amount_desc
              },
              igst_rate: %{anyOf: [%{type: "number"}, %{type: "null"}], description: rate_desc},
              igst_amount: %{
                anyOf: [%{type: "number"}, %{type: "null"}],
                description: amount_desc
              }
            }
          }
        },
        printed_total_taxable: %{
          type: "number",
          description:
            "Printed taxable total, extracted only for reconciliation checks. Do not use as truth if line sums differ. " <>
              amount_desc
        },
        printed_total_tax: %{
          type: "number",
          description:
            "Printed total GST amount, extracted only for reconciliation checks. Do not use as truth if line sums differ. " <>
              amount_desc
        },
        printed_grand_total: %{
          type: "number",
          description:
            "Printed grand total including GST. Line items are authoritative and this total may be wrong. " <>
              amount_desc
        }
      },
      required: ["is_invoice", "invoice_number", "invoice_date", "seller", "buyer", "line_items"]
    }
  end
end

PurchaseExtractScript.run(System.argv())
