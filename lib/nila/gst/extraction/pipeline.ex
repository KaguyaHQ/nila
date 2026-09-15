defmodule Nila.Gst.Extraction.Pipeline do
  @moduledoc """
  Discovers document pages, reads each invoice, and assembles evidence and audits.

  Sales callers can explicitly select `input: :text` for known digital PDFs.
  Native text feeds the same labels and invoice schema; blank pages retain vision,
  and page images remain the review evidence. The default is still vision.

  The provider returns structured candidates only. Phoenix still repairs known identities,
  checks arithmetic and builds the purchase or sales artifact consumed downstream.
  """

  alias Nila.Gst.Extraction.Discovery.SalesPages
  alias Nila.Gst.Extraction.Discovery.PurchasePages
  alias Nila.Gst.Extraction.InvoiceRepairs
  alias Nila.Gst.Extraction.InvoiceRequest
  alias Nila.Gst.Extraction.InvoiceSchema
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.SourcePages
  alias Nila.Gst.Extraction.InvoiceVerification

  @default_max_concurrency 100

  def extract(kind, bytes, opts \\ [])
      when kind in [:purchase, :sales] and is_binary(bytes) do
    hooks = %{
      per_call: Keyword.get(opts, :per_call) || (&call_through/2),
      on_progress: Keyword.get(opts, :on_progress) || (&ignore_progress/1)
    }

    with {:ok, source} <- SourcePages.prepare(kind, bytes, opts),
         {:ok, discovery} <- discover_or_resume(kind, source, opts, hooks),
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

    with {:ok, source} <- SourcePages.prepare(kind, bytes, opts),
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
                  Map.merge(SourcePages.input_metadata(source), %{
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
              {:error, reason, Map.put(audit, :metadata, SourcePages.input_metadata(source))}
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

  defp discover_or_resume(kind, source, opts, hooks) do
    case Keyword.get(opts, :resume_segments) do
      nil ->
        discover(kind, source, opts, hooks)

      segments ->
        {:ok,
         %{
           segments:
             Enum.map(segments, fn segment ->
               %{
                 pages: segment["pages"],
                 kind: if(segment["kind"] == "invoice", do: :invoice, else: :other),
                 invoice_no: segment["invoice_no"],
                 document_type: segment["document_type"],
                 reason: segment["reason"],
                 issues: []
               }
             end)
         }}
    end
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
              if(SourcePages.text_page?(source, page),
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

  defp segmentation_prompt(:sales, page_count), do: SalesPages.prompt(page_count)
  defp segmentation_prompt(:purchase, page_count), do: PurchasePages.prompt(page_count)

  defp segmentation_schema(:sales), do: SalesPages.schema()
  defp segmentation_schema(:purchase), do: PurchasePages.schema()

  defp group_pages(:sales, pages, count), do: SalesPages.group(pages, count)
  defp group_pages(:purchase, pages, count), do: PurchasePages.group(pages, count)

  defp read_segments(kind, source, discovery, opts, hooks) do
    discovery =
      Map.update!(
        discovery,
        :segments,
        &Enum.sort_by(&1, fn segment -> List.first(segment.pages) end)
      )

    segments = Enum.filter(discovery.segments, &(&1.kind == :invoice))
    on_invoice = Keyword.get(opts, :on_invoice, fn _artifact, _ordinal, _evidence -> :ok end)
    Keyword.get(opts, :on_segments, fn _segments -> :ok end).(encode_segments(discovery.segments))
    completed = Keyword.get(opts, :completed_artifacts, %{})
    report(hooks, %{stage: :reading, done: 0, total: length(segments)})

    stage = if map_size(source.native_text) > 0, do: "text_extraction", else: "vision_extraction"

    hooks.per_call.(%{stage: stage, segments: length(segments)}, fn ->
      results =
        segments
        |> Enum.with_index(1)
        |> Task.async_stream(
          fn {segment, ordinal} ->
            result =
              case completed[to_string(ordinal)] do
                nil -> contained(segment, fn -> extract_segment(kind, source, segment, opts) end)
                artifact -> {:ok, artifact, nil}
              end

            {ordinal, result}
          end,
          max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
          ordered: false,
          timeout: :infinity
        )
        |> Stream.with_index(1)
        |> Enum.map(fn {{:ok, {ordinal, result}}, done} ->
          result =
            case result do
              {:ok, artifact, response} ->
                on_invoice.(artifact, ordinal, source.evidence)
                {:ok, artifact, response}

              other ->
                Keyword.get(opts, :on_invoice_failed, fn _ordinal -> :ok end).(ordinal)
                other
            end

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
          {:ok, _artifact, nil} ->
            []

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
          Map.merge(SourcePages.input_metadata(source), %{
            "contract" => to_string(Keyword.get(opts, :contract, :current)),
            "segments" => encode_segments(discovery.segments),
            "invoice_inputs" =>
              Enum.map(segments, fn segment ->
                %{
                  "pages" => segment.pages,
                  "input" =>
                    if(Enum.all?(segment.pages, &SourcePages.text_page?(source, &1)),
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
    contract = Keyword.get(opts, :contract, :current)
    request = invoice_request(kind, segment.pages, source, contract)
    schema = request.schema

    with :ok <- SourcePages.validate_segment_images(source.full, segment),
         {:ok, response} <-
           OpenAICompatibleChat.request_raw(
             request.messages,
             request.name,
             schema,
             request_opts(opts)
           ) do
      case OpenAICompatibleChat.decode(response, schema) do
        {:ok, data, usage} ->
          data = data |> InvoiceSchema.decode_line_items(contract) |> Map.put("usage", usage)
          {:ok, artifact(kind, data, segment, source, opts), response}

        {:error, reason} ->
          {:error, segment, reason, response}
      end
    else
      {:error, reason} -> {:error, segment, reason, nil}
    end
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

  defp invoice_request(kind, pages, source, contract) do
    {modality, inputs} = SourcePages.invoice_inputs(source, pages)
    InvoiceRequest.build(kind, inputs, modality, contract)
  end

  defp artifact(kind, data, segment, source, opts) do
    usage = Map.get(data, "usage", %{})
    data = Map.delete(data, "usage")

    data =
      if kind == :sales do
        text = Enum.map_join(segment.pages, "\n", &Map.get(source.native_text, &1, ""))

        Nila.Gst.Extraction.Sales.SellerIdentity.apply(
          data,
          Keyword.get(opts, :client_gstin),
          text
        )
      else
        data
      end

    {data, repairs} =
      InvoiceRepairs.prepare(data, kind, Keyword.get(opts, :client_gstin))

    reverse_charge? = data["reverse_charge"] == true

    tax_excluded? =
      reverse_charge? or
        (kind == :sales and data["supply_type"] in ["export", "sez"] and
           data["tax_payment"] == "without_payment")

    verification = InvoiceVerification.structured(data, tax_excluded?)
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
