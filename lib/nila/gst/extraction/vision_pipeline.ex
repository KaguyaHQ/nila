defmodule Nila.Gst.Extraction.VisionPipeline do
  @moduledoc """
  Segments a packet from page thumbnails, then reads each invoice from its page images.

  The provider returns structured candidates only. Phoenix still repairs known identities,
  checks arithmetic and builds the purchase or sales artifact consumed downstream.
  """

  alias Nila.Gst.Extraction.Discovery.PageLabels
  alias Nila.Gst.Extraction.Evidence
  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.Segmented
  alias Nila.Gst.Extraction.Verify

  @max_concurrency 4
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

    with {:ok, source} <- render(bytes, opts),
         {:ok, discovery} <- discover(kind, source, opts, hooks),
         {:ok, result} <- read_segments(kind, source, discovery, opts, hooks) do
      {:ok, result}
    else
      {:error, reason, _audit} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render(bytes, opts) do
    filename = Keyword.get(opts, :filename, "document.pdf")
    content_type = Keyword.get(opts, :content_type) || Mistral.content_type(filename)

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

    hooks.per_call.(%{stage: "vision_segmentation", pages: source.page_count}, fn ->
      case request_segmentation(kind, source.thumbnails, source.page_count, opts) do
        {:ok, response} ->
          with {:ok, %{"pages" => pages}, usage} <-
                 OpenAICompatibleChat.decode(response, segmentation_schema()),
               {:ok, labels} <- decode_labels(pages, source.page_count) do
            segments = PageLabels.stitch(labels)

            result = %{
              segments: segments,
              labels: labels,
              audit: %{
                provider: OpenAICompatibleChat.provider(),
                model: OpenAICompatibleChat.model(),
                http_status: response.status,
                provider_request_id: request_id(response.headers),
                source_page_count: source.page_count,
                usage: usage,
                raw_response: response.body,
                metadata: %{
                  "segments" => encode_segments(segments),
                  "retry_count" => Map.get(response, :retry_count, 0)
                }
              }
            }

            report(hooks, %{
              stage: :segmenting,
              done: source.page_count,
              total: source.page_count
            })

            {:ok, result}
          else
            {:error, reason} -> {:error, reason, response_audit(response, source.page_count)}
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

  defp request_segmentation(kind, pages, page_count, opts) do
    content =
      Enum.reduce(
        1..page_count,
        [%{type: "text", text: segmentation_prompt(kind, page_count)}],
        fn page, acc ->
          acc ++
            [
              %{type: "text", text: "PHYSICAL PAGE #{page}"},
              image_part(Map.fetch!(pages, page))
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
      segmentation_schema(),
      request_opts(opts)
    )
  end

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

  defp segmentation_schema do
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

    hooks.per_call.(%{stage: "vision_extraction", segments: length(segments)}, fn ->
      results =
        segments
        |> Task.async_stream(
          fn segment ->
            contained(segment, fn -> extract_segment(kind, source, segment, opts) end)
          end,
          max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
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
        usage: responses |> Enum.map(& &1.usage) |> Segmented.sum_usage(),
        raw_response: Jason.encode!(%{"responses" => responses}),
        metadata: %{
          "segments" => encode_segments(discovery.segments),
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
        }
      }

      cond do
        failures != [] ->
          {:error, {:invoice_segments_failed, failures}, audit}

        artifacts == [] ->
          {:error, {:no_invoices_extracted, []}, audit}

        true ->
          {:ok,
           %{
             pages: artifacts,
             images: source.evidence,
             audit: audit,
             unaccounted_pages: unaccounted_pages(source.page_count, discovery.segments)
           }}
      end
    end)
  end

  defp extract_segment(kind, source, segment, opts) do
    schema = vision_schema(kind)

    with :ok <- validate_segment_images(source.full, segment),
         messages = vision_messages(kind, segment.pages, source.full),
         {:ok, response} <-
           OpenAICompatibleChat.request_raw(
             messages,
             "nila_direct_#{kind}_invoice",
             schema,
             request_opts(opts)
           ) do
      case OpenAICompatibleChat.decode(response, schema) do
        {:ok, data, usage} ->
          data = Map.put(data, "usage", usage)
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

  defp vision_messages(kind, pages, images) do
    page_list = Enum.join(pages, ", ")

    instruction =
      Segmented.prompt(kind)
      |> String.replace("OCR text", "page images")
      |> Kernel.<>("""

      These are physical PDF pages #{page_list}, in order. Read the pixels directly.
      Interpret ordinary numeric Indian invoice dates as DD/MM/YYYY, never MM/DD/YYYY,
      and preserve the printed date text in invoice_date.
      Reconcile ambiguous decimal placement and separate rupee/paise columns against
      printed totals and amount in words. Reconciliation may disambiguate a visible
      value; it must not invent a value absent from the document.
      Set reverse_charge true only when the document positively states that tax is
      payable under reverse charge, false when it explicitly says no, and null otherwise.
      """)

    content =
      Enum.reduce(pages, [%{type: "text", text: instruction}], fn page, acc ->
        acc ++
          [
            %{type: "text", text: "PHYSICAL PAGE #{page}"},
            image_part(Map.fetch!(images, page))
          ]
      end)

    [
      %{role: "system", content: "You read invoices from page images into JSON."},
      %{role: "user", content: content}
    ]
  end

  defp vision_schema(kind) do
    schema = Segmented.schema(kind)
    reverse_charge = %{anyOf: [%{type: "boolean"}, %{type: "null"}]}

    schema
    |> put_in([:properties, :reverse_charge], reverse_charge)
    |> update_in([:required], &(&1 ++ ["reverse_charge"]))
  end

  defp artifact(kind, data, segment, source, opts) do
    usage = Map.get(data, "usage", %{})
    data = Map.delete(data, "usage")

    {data, repairs} =
      Segmented.prepare_vision_data(data, kind, Keyword.get(opts, :client_gstin))

    reverse_charge? = data["reverse_charge"] == true
    verification = Verify.structured(data, reverse_charge?)
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
        "invoice_no" => segment.invoice_no
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
end
