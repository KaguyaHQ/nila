defmodule Nila.Gst.Extraction.VisionPipeline do
  @moduledoc """
  Segments a packet from page thumbnails, then reads each invoice from its page images.

  Sales callers can explicitly select `input: :text` for known digital PDFs.
  Native text feeds the same labels and invoice schema; blank pages retain vision,
  and page images remain the review evidence. The default is still vision.

  The provider returns structured candidates only. Phoenix still repairs known identities,
  checks arithmetic and builds the purchase or sales artifact consumed downstream.
  """

  alias Nila.Gst.Extraction.Discovery.DocumentPages
  alias Nila.Gst.Extraction.Discovery.PageLabels
  alias Nila.Gst.Extraction.Evidence
  alias Nila.Gst.Extraction.InvoiceData
  alias Nila.Gst.Extraction.InvoiceRequest
  alias Nila.Gst.Extraction.InvoiceSchema
  alias Nila.Gst.Extraction.NativeText
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.Verify

  @max_pages 100
  @max_thumbnail_bytes 10_000_000
  @max_full_image_bytes 100_000_000
  @max_segment_image_bytes 20_000_000
  @max_image_bytes 20_000_000
  @thumbnail_dpi 75
  @thumbnail_quality 70
  @image_extensions %{
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/webp" => "webp"
  }
  def extract(kind, bytes, opts \\ [])
      when kind in [:purchase, :sales] and is_binary(bytes) do
    hooks = %{
      per_call: Keyword.get(opts, :per_call) || (&call_through/2),
      on_progress: Keyword.get(opts, :on_progress) || (&ignore_progress/1)
    }

    with {:ok, source} <- prepare(kind, bytes, opts),
         {:ok, discovery} <- discover(kind, source, opts, hooks),
         {:ok, result} <- read_segments(kind, source, discovery, opts, hooks) do
      {:ok, result}
    else
      {:error, reason, _audit} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs invoice extraction against fixed, human-selected page groups.

  This is the eval seam for schema experiments: it deliberately skips model
  segmentation while retaining the production render, selected input prompt,
  tuple schema, decoder, repairs, and verification path.
  """
  def extract_fixed_segments(kind, bytes, page_groups, opts \\ [])
      when kind in [:purchase, :sales] and is_binary(bytes) and is_list(page_groups) do
    hooks = %{
      per_call: Keyword.get(opts, :per_call) || (&call_through/2),
      on_progress: Keyword.get(opts, :on_progress) || (&ignore_progress/1)
    }

    with {:ok, source} <- prepare(kind, bytes, opts),
         {:ok, segments} <- fixed_segments(page_groups, source.page_count),
         {:ok, result} <- read_segments(kind, source, %{segments: segments}, opts, hooks) do
      {:ok, result}
    else
      {:error, reason, _audit} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fixed_segments(page_groups, page_count) do
    valid? =
      page_groups != [] and
        Enum.all?(page_groups, fn pages ->
          is_list(pages) and pages != [] and
            Enum.all?(pages, &(is_integer(&1) and &1 in 1..page_count)) and
            pages == Enum.sort(Enum.uniq(pages))
        end)

    if valid? do
      {:ok,
       Enum.map(page_groups, fn pages ->
         %{
           pages: pages,
           kind: :invoice,
           invoice_no: nil,
           reason: "fixed_eval_boundary",
           issues: []
         }
       end)}
    else
      {:error, {:invalid_fixed_segments, page_groups, page_count}}
    end
  end

  # Keep vision as the default. Native text is explicitly selected for known
  # digital sales PDFs; selectable OCR layers are not automatically trusted.
  defp prepare(kind, bytes, opts) do
    input = Keyword.get(opts, :input, :vision)

    with :ok <- validate_input(kind, input),
         {:ok, source} <- render(bytes, opts) do
      content_type =
        Keyword.get(opts, :content_type) ||
          Evidence.content_type(Keyword.get(opts, :filename, "document.pdf"))

      if input == :text and content_type == "application/pdf" do
        with {:ok, text} <- NativeText.extract(bytes, source.page_count) do
          {:ok, Map.put(source, :native_text, text)}
        end
      else
        {:ok, Map.put(source, :native_text, %{})}
      end
    end
  end

  defp validate_input(_kind, :vision), do: :ok
  defp validate_input(:sales, :text), do: :ok
  defp validate_input(kind, input), do: {:error, {:unsupported_extraction_input, kind, input}}

  defp text_page?(source, page) do
    source.native_text |> Map.get(page, "") |> String.trim() != ""
  end

  defp input_metadata(source) do
    %{
      "native_text" =>
        Map.new(source.native_text, fn {page, text} -> {to_string(page), text} end),
      "text_pages" => Enum.filter(1..source.page_count, &text_page?(source, &1))
    }
  end

  defp render(bytes, opts) do
    filename = Keyword.get(opts, :filename, "document.pdf")
    content_type = Keyword.get(opts, :content_type) || Evidence.content_type(filename)

    cond do
      content_type == "application/pdf" ->
        with {:ok, thumbnails} <-
               Evidence.render_pages(
                 bytes,
                 opts
                 |> Keyword.put(:dpi, @thumbnail_dpi)
                 |> Keyword.put(:jpeg_quality, @thumbnail_quality)
                 |> Keyword.put(:last_page, @max_pages + 1)
               ),
             :ok <- validate_packet(thumbnails),
             {:ok, evidence} <- Evidence.render_pages(bytes, opts),
             :ok <- validate_full_images(evidence) do
          {:ok,
           %{
             full: pdf_pages(evidence),
             thumbnails: pdf_pages(thumbnails),
             evidence: evidence,
             page_count: map_size(evidence)
           }}
        end

      extension = @image_extensions[content_type] ->
        if byte_size(bytes) <= @max_image_bytes do
          basename = "page_01.#{extension}"
          page = %{bytes: bytes, content_type: content_type, basename: basename}

          {:ok,
           %{
             full: %{1 => page},
             thumbnails: %{1 => page},
             evidence: %{basename => bytes},
             page_count: 1
           }}
        else
          {:error, {:vision_image_too_large, byte_size(bytes), @max_image_bytes}}
        end

      true ->
        {:error, {:unsupported_content_type, content_type}}
    end
  end

  defp validate_packet(images) do
    page_count = map_size(images)
    image_bytes = images |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

    cond do
      page_count == 0 ->
        {:error, :vision_packet_has_no_pages}

      page_count > @max_pages ->
        {:error, {:vision_packet_too_many_pages, page_count, @max_pages}}

      image_bytes > @max_thumbnail_bytes ->
        {:error, {:vision_packet_too_large, image_bytes, @max_thumbnail_bytes}}

      true ->
        :ok
    end
  end

  defp validate_full_images(images) do
    image_bytes = images |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

    if image_bytes > @max_full_image_bytes,
      do: {:error, {:vision_render_too_large, image_bytes, @max_full_image_bytes}},
      else: :ok
  end

  defp pdf_pages(images) do
    Map.new(images, fn {basename, bytes} ->
      [number] = Regex.run(~r/page_(\d+)\.jpg$/, basename, capture: :all_but_first)

      {String.to_integer(number), %{bytes: bytes, content_type: "image/jpeg", basename: basename}}
    end)
  end

  defp discover(kind, source, opts, hooks) do
    report(hooks, %{stage: :segmenting, done: 0, total: source.page_count})

    stage =
      if map_size(source.native_text) > 0, do: "text_segmentation", else: "vision_segmentation"

    hooks.per_call.(%{stage: stage, pages: source.page_count}, fn ->
      case request_segmentation(kind, source, opts) do
        {:ok, response} ->
          with {:ok, %{"pages" => pages}, usage} <-
                 OpenAICompatibleChat.decode(response, segmentation_schema(kind)),
               {:ok, segments} <- group_pages(kind, pages, source.page_count) do
            result = %{
              segments: segments,
              labels: pages,
              audit: %{
                provider: OpenAICompatibleChat.provider(),
                model: OpenAICompatibleChat.model(),
                http_status: response.status,
                provider_request_id: request_id(response.headers),
                source_page_count: source.page_count,
                usage: usage,
                raw_response: response.body,
                metadata:
                  Map.merge(input_metadata(source), %{
                    "segments" => encode_segments(segments),
                    "retry_count" => Map.get(response, :retry_count, 0)
                  })
              }
            }

            report(hooks, %{
              stage: :segmenting,
              done: source.page_count,
              total: source.page_count
            })

            {:ok, result}
          else
            {:error, reason} ->
              audit = response_audit(response, source.page_count)
              {:error, reason, Map.put(audit, :metadata, input_metadata(source))}
          end

        {:error, reason} ->
          {:error, reason,
           %{
             provider: OpenAICompatibleChat.provider(),
             model: OpenAICompatibleChat.model(),
             source_page_count: source.page_count
           }}
      end
    end)
  end

  defp request_segmentation(kind, source, opts) do
    page_count = source.page_count

    content =
      Enum.reduce(
        1..page_count,
        [%{type: "text", text: segmentation_prompt(kind, page_count)}],
        fn page, acc ->
          acc ++
            [
              %{type: "text", text: "PHYSICAL PAGE #{page}"},
              if(text_page?(source, page),
                do: %{type: "text", text: Map.fetch!(source.native_text, page)},
                else: image_part(Map.fetch!(source.thumbnails, page))
              )
            ]
        end
      )

    messages = [
      %{role: "system", content: "You split ordered invoice packets. Answer only in JSON."},
      %{role: "user", content: content}
    ]

    OpenAICompatibleChat.request_raw(
      messages,
      "nila_packet_page_labels",
      segmentation_schema(kind),
      request_opts(opts)
    )
  end

  defp segmentation_prompt(:sales, page_count), do: DocumentPages.prompt(page_count)

  defp segmentation_prompt(kind, page_count) do
    """
    Label every page of this ordered packet of Indian GST #{kind} invoices.
    Return exactly one entry for every physical page, numbered 1 through #{page_count}.

    - start: this page begins a new invoice, credit note or debit note.
    - continuation: this page carries on the invoice from the preceding page.
    - non_invoice: standalone challan, e-way bill, purchase order, receipt, blank or separator.
    - unreadable: the image is too damaged to decide.
    - A repeated seller is not enough to join pages. Use document number, customer,
      explicit page numbering, continued item tables and closing totals.
    - A repeated complete scan is a new start even when its invoice number matches the
      preceding page. Only an incomplete document page can be a continuation.
    - invoice_no must be visible on that page itself; otherwise return null.
    Do not extract line items or totals. Return only the page labels.
    """
  end

  defp segmentation_schema(:sales), do: DocumentPages.schema()

  defp segmentation_schema(:purchase) do
    %{
      type: "object",
      additionalProperties: false,
      required: ["pages"],
      properties: %{
        pages: %{
          type: "array",
          items: %{
            type: "object",
            additionalProperties: false,
            required: ["page", "label", "invoice_no", "reason"],
            properties: %{
              page: %{type: "integer"},
              label: %{
                type: "string",
                enum: ["start", "continuation", "non_invoice", "unreadable"]
              },
              invoice_no: %{anyOf: [%{type: "string"}, %{type: "null"}]},
              reason: %{anyOf: [%{type: "string"}, %{type: "null"}]}
            }
          }
        }
      }
    }
  end

  defp decode_labels(pages, expected_count) do
    expected = Enum.to_list(1..expected_count)
    actual = Enum.map(pages, & &1["page"])

    if actual == expected do
      {:ok,
       Enum.map(pages, fn page ->
         %{
           page: page["page"],
           label: label(page["label"]),
           invoice_no: blank_to_nil(page["invoice_no"]),
           reason: blank_to_nil(page["reason"]),
           usage: %{}
         }
       end)}
    else
      {:error, {:page_conservation, expected, actual}}
    end
  end

  defp label("start"), do: :start
  defp label("continuation"), do: :continuation
  defp label("non_invoice"), do: :non_invoice
  defp label(_unreadable), do: :unreadable

  defp group_pages(:sales, pages, count), do: DocumentPages.group(pages, count)

  defp group_pages(:purchase, pages, count) do
    with {:ok, labels} <- decode_labels(pages, count) do
      {:ok, PageLabels.stitch(labels)}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(_value), do: nil

  defp read_segments(kind, source, discovery, opts, hooks) do
    segments = Enum.filter(discovery.segments, &(&1.kind == :invoice))
    report(hooks, %{stage: :reading, done: 0, total: length(segments)})

    stage = if map_size(source.native_text) > 0, do: "text_extraction", else: "vision_extraction"

    hooks.per_call.(%{stage: stage, segments: length(segments)}, fn ->
      results =
        segments
        |> Task.async_stream(
          fn segment ->
            contained(segment, fn -> extract_segment(kind, source, segment, opts) end)
          end,
          max_concurrency: Keyword.get(opts, :max_concurrency, @max_pages),
          ordered: false,
          timeout: :infinity
        )
        |> Stream.with_index(1)
        |> Enum.map(fn {{:ok, result}, done} ->
          report(hooks, %{stage: :reading, done: done, total: length(segments)})
          result
        end)

      artifacts =
        results
        |> Enum.flat_map(fn
          {:ok, artifact, _response} -> [artifact]
          _failed -> []
        end)
        |> Enum.sort_by(& &1["page"])

      failures =
        Enum.flat_map(results, fn
          {:error, segment, reason, _response} ->
            [%{pages: segment.pages, reason: reason}]

          _success ->
            []
        end)

      responses =
        Enum.flat_map(results, fn
          {:ok, artifact, response} ->
            [response_record(response, artifact["source_pages"])]

          {:error, _segment, _reason, nil} ->
            []

          {:error, segment, _reason, response} ->
            [response_record(response, segment.pages)]
        end)

      audit = %{
        provider: OpenAICompatibleChat.provider(),
        model: OpenAICompatibleChat.model(),
        source_page_count: source.page_count,
        usage: responses |> Enum.map(& &1.usage) |> sum_usage(),
        raw_response: Jason.encode!(%{"responses" => responses}),
        metadata:
          Map.merge(input_metadata(source), %{
            "segments" => encode_segments(discovery.segments),
            "invoice_inputs" =>
              Enum.map(segments, fn segment ->
                %{
                  "pages" => segment.pages,
                  "input" =>
                    if(Enum.all?(segment.pages, &text_page?(source, &1)),
                      do: "text",
                      else: "vision"
                    )
                }
              end),
            "failures" =>
              Enum.map(failures, &%{"pages" => &1.pages, "reason" => inspect(&1.reason)}),
            "responses" =>
              Enum.map(
                responses,
                &Map.take(&1, [:pages, :provider_request_id, :retry_count, :status])
              ),
            "repairs" =>
              artifacts
              |> Enum.flat_map(&(&1["repairs"] || []))
              |> Enum.map(&Map.take(&1, ["field", "from", "to", "basis"]))
          })
      }

      cond do
        failures != [] ->
          {:error, {:invoice_segments_failed, failures}, audit}

        artifacts == [] and kind != :sales ->
          {:error, {:no_invoices_extracted, []}, audit}

        true ->
          {:ok,
           %{
             pages: artifacts,
             images: source.evidence,
             excluded_documents:
               discovery.segments |> Enum.reject(&(&1.kind == :invoice)) |> encode_segments(),
             audit: audit,
             unaccounted_pages: unaccounted_pages(source.page_count, discovery.segments)
           }}
      end
    end)
  end

  defp extract_segment(kind, source, segment, opts) do
    request = invoice_request(kind, segment.pages, source)
    schema = request.schema

    with :ok <- validate_segment_images(source.full, segment),
         {:ok, response} <-
           OpenAICompatibleChat.request_raw(
             request.messages,
             request.name,
             schema,
             request_opts(opts)
           ) do
      case OpenAICompatibleChat.decode(response, schema) do
        {:ok, data, usage} ->
          data = data |> InvoiceSchema.decode_line_items() |> Map.put("usage", usage)
          {:ok, artifact(kind, data, segment, source, opts), response}

        {:error, reason} ->
          {:error, segment, reason, response}
      end
    else
      {:error, reason} -> {:error, segment, reason, nil}
    end
  end

  defp validate_segment_images(images, segment) do
    image_bytes =
      segment.pages
      |> Enum.map(&(images |> Map.fetch!(&1) |> Map.fetch!(:bytes)))
      |> Enum.map(&byte_size/1)
      |> Enum.sum()

    if image_bytes > @max_segment_image_bytes,
      do:
        {:error,
         {:vision_segment_too_large, segment.pages, image_bytes, @max_segment_image_bytes}},
      else: :ok
  end

  defp contained(segment, call) do
    try do
      call.()
    rescue
      error -> {:error, segment, {:segment_crashed, Exception.message(error)}, nil}
    catch
      kind, value -> {:error, segment, {:segment_crashed, inspect({kind, value})}, nil}
    end
  end

  defp invoice_request(kind, pages, source) do
    # A scanned continuation requires images for the entire invoice.
    modality = if Enum.all?(pages, &text_page?(source, &1)), do: :text, else: :vision

    inputs =
      Enum.map(pages, fn page ->
        content =
          if modality == :text,
            do: Map.fetch!(source.native_text, page),
            else: Map.fetch!(source.full, page)

        {page, content}
      end)

    InvoiceRequest.build(kind, inputs, modality)
  end

  defp artifact(kind, data, segment, source, opts) do
    usage = Map.get(data, "usage", %{})
    data = Map.delete(data, "usage")

    {data, repairs} =
      InvoiceData.prepare(data, kind, Keyword.get(opts, :client_gstin))

    reverse_charge? = data["reverse_charge"] == true

    tax_excluded? =
      reverse_charge? or
        (kind == :sales and data["supply_type"] in ["export", "sez"] and
           data["tax_payment"] == "without_payment")

    verification = Verify.structured(data, tax_excluded?)
    type = data["document_type"]

    %{
      "kind" => artifact_kind(kind),
      "version" => 1,
      "page" => List.first(segment.pages),
      "source_pages" => segment.pages,
      "source_attribution" => %{
        "status" => "verified",
        "candidate_pages" => segment.pages,
        "source" => "segment"
      },
      "image" => get_in(source.full, [List.first(segment.pages), :basename]),
      "data" => data,
      "confidence" => %{
        "source_attribution" => 1.0,
        "verification" => to_string(verification.status)
      },
      "verification" => %{
        "status" => to_string(verification.status),
        "flags" => Enum.map(verification.flags, &encode_flag/1),
        "failed_checks" =>
          verification.checks
          |> Enum.reject(& &1.ok?)
          |> Enum.map(
            &%{
              "kind" => to_string(&1.kind),
              "field" => &1.field,
              "detail" => inspect(&1.detail)
            }
          )
      },
      "repairs" => repairs,
      "document" => %{
        "credit_note" => type == "credit_note",
        "debit_note" => type == "debit_note",
        "export" => data["supply_type"] in ["export", "sez"],
        "reverse_charge" => reverse_charge?,
        "extracted_type" => type
      },
      "usage" => usage,
      "segment" => %{
        "pages" => segment.pages,
        "invoice_no_candidate" => segment.invoice_no,
        "issues" => Enum.map(segment.issues, &inspect(&1, charlists: :as_lists))
      }
    }
  end

  defp image_part(image) do
    %{
      type: "image_url",
      image_url: %{
        url: "data:#{image.content_type};base64," <> Base.encode64(image.bytes)
      }
    }
  end

  defp request_opts(opts) do
    [
      max_retries: Keyword.get(opts, :max_retries, 8),
      response_format: :json_schema_local
    ]
  end

  defp response_record(response, pages) do
    %{
      pages: pages,
      status: response.status,
      provider_request_id: request_id(response.headers),
      retry_count: Map.get(response, :retry_count, 0),
      usage: response_usage(response.body),
      body: response.body
    }
  end

  defp response_usage(body) do
    case Jason.decode(body) do
      {:ok, %{"usage" => usage}} when is_map(usage) -> usage
      _other -> %{}
    end
  end

  defp response_audit(response, page_count) do
    %{
      provider: OpenAICompatibleChat.provider(),
      model: OpenAICompatibleChat.model(),
      http_status: response.status,
      provider_request_id: request_id(response.headers),
      source_page_count: page_count,
      usage: response_usage(response.body),
      raw_response: response.body
    }
  end

  defp request_id(headers) do
    headers
    |> Map.get("x-request-id", [])
    |> List.first()
  end

  defp encode_segments(segments) do
    Enum.map(segments, fn segment ->
      %{
        "pages" => segment.pages,
        "kind" => to_string(segment.kind),
        "invoice_no" => segment.invoice_no,
        "document_type" => Map.get(segment, :document_type),
        "reason" => Map.get(segment, :reason)
      }
    end)
  end

  defp unaccounted_pages(page_count, segments) do
    accounted =
      segments
      |> Enum.filter(&(&1.kind == :invoice))
      |> Enum.flat_map(& &1.pages)
      |> MapSet.new()

    Enum.reject(1..page_count, &MapSet.member?(accounted, &1))
  end

  defp artifact_kind(:purchase), do: "purchase_invoice_extraction"
  defp artifact_kind(:sales), do: "gstr1_sales_invoice_extraction"

  defp encode_flag({name, detail}),
    do: %{"flag" => to_string(name), "detail" => inspect(detail)}

  defp report(%{on_progress: on_progress}, progress), do: on_progress.({:progress, progress})
  defp call_through(_metadata, call), do: call.()
  defp ignore_progress(_progress), do: :ok

  # Add token counts across calls, preserving provider keys.
  defp sum_usage(usages) do
    usages
    |> Enum.reject(&(!is_map(&1)))
    |> Enum.reduce(%{}, fn usage, acc ->
      Map.merge(acc, usage, fn
        _key, left, right when is_number(left) and is_number(right) -> left + right
        _key, left, _right -> left
      end)
    end)
  end
end
