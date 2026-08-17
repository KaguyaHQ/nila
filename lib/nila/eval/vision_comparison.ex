defmodule Nila.Eval.VisionComparison do
  @moduledoc """
  Compares the existing OCR-to-text pipeline with direct vision over fixed,
  human-reviewed invoice boundaries. Every final provider response and rendered
  page is retained under one eval attempt.
  """

  alias Nila.Eval
  alias Nila.Eval.Segmentation
  alias Nila.Eval.Transcription, as: EvalTranscription
  alias Nila.EvalCorpus
  alias Nila.Gst.Extraction.Discovery
  alias Nila.Gst.Extraction.Discovery.PageLabels
  alias Nila.Gst.Extraction.Providers.{Mistral, OpenAICompatibleChat}
  alias Nila.Gst.Extraction.Segmented
  alias Nila.Gst.Sales.Gstr1

  @root "tmp/eval/vision-comparisons"
  @approaches ~w(mistral_text qwen_vision)

  def run(names, opts \\ []) when is_list(names) do
    concurrency = Keyword.get(opts, :max_concurrency, 4)
    report = Keyword.get(opts, :on_event, fn _event -> :ok end)
    original_text_config = Application.get_env(:nila, OpenAICompatibleChat, [])
    dir = Path.join(@root, attempt_id())

    File.mkdir_p!(dir)

    try do
      with {:ok, documents} <- prepare_documents(names, dir, report),
           :ok <- write_manifest(dir, documents, concurrency, original_text_config),
           {:ok, mistral} <-
             with_text_config(mistral_text_config(original_text_config), fn ->
               capture_approach("mistral_text", documents, dir, concurrency, report)
             end),
           {:ok, qwen} <-
             with_text_config(original_text_config, fn ->
               capture_approach("qwen_vision", documents, dir, concurrency, report)
             end) do
        comparison = build_comparison(documents, mistral, qwen, dir)
        write_reports!(dir, comparison)
        {:ok, comparison}
      end
    after
      Application.put_env(:nila, OpenAICompatibleChat, original_text_config)
    end
  end

  @doc "Rebuilds summary and HTML from one comparison's cached provider responses."
  def rebuild(dir) do
    documents = load_documents(dir)
    mistral = read_json!(Path.join(dir, "mistral_text.json"))
    qwen = read_json!(Path.join(dir, "qwen_vision.json"))
    comparison = build_comparison(documents, mistral, qwen, dir)

    comparison =
      case Path.join(dir, "segmentation/report.json") do
        path when is_binary(path) ->
          if File.exists?(path) do
            segmentation =
              path
              |> read_json!()
              |> add_raw_segmentation_scores(documents)
              |> add_segmentation_operations(dir)

            write_json!(path, segmentation)
            Map.put(comparison, "segmentation", segmentation)
          else
            comparison
          end
      end

    write_reports!(dir, comparison)
    {:ok, comparison}
  end

  @doc "Compares OCR-text and direct-vision segmentation against the fixed boundaries."
  def segment(dir, opts \\ []) do
    concurrency = Keyword.get(opts, :max_concurrency, 4)
    report = Keyword.get(opts, :on_event, fn _event -> :ok end)
    documents = load_documents(dir)
    original_text_config = Application.get_env(:nila, OpenAICompatibleChat, [])
    segmentation_dir = Path.join(dir, "segmentation")
    File.mkdir_p!(segmentation_dir)

    try do
      mistral =
        with_text_config(mistral_text_config(original_text_config), fn ->
          segment_mistral(documents, segmentation_dir, concurrency, report)
        end)

      qwen =
        with_text_config(original_text_config, fn ->
          segment_qwen(documents, segmentation_dir, report, "qwen_vision", "")
        end)

      result = %{
        "mistral_text" => mistral,
        "qwen_vision" => qwen,
        "created_at" => stamp()
      }

      write_json!(Path.join(segmentation_dir, "report.json"), result)
      {:ok, comparison} = rebuild(dir)
      {:ok, comparison}
    after
      Application.put_env(:nila, OpenAICompatibleChat, original_text_config)
    end
  end

  @doc "Retries vision segmentation with the explicit complete-duplicate boundary rule."
  def segment_qwen_duplicate_rule(dir, opts \\ []) do
    report = Keyword.get(opts, :on_event, fn _event -> :ok end)
    documents = load_documents(dir)
    original_text_config = Application.get_env(:nila, OpenAICompatibleChat, [])
    segmentation_dir = Path.join(dir, "segmentation")
    approach = "qwen_vision_duplicate_rule"

    try do
      results =
        with_text_config(original_text_config, fn ->
          segment_qwen(documents, segmentation_dir, report, approach, """
          A repeated complete scan of an invoice is a new start, even when its
          document number is identical to the preceding page. Use continuation
          only for an incomplete page that carries on the preceding invoice.
          """)
        end)

      results =
        Map.new(results, fn {name, result} -> {name, Map.put(result, "post_hoc", true)} end)

      path = Path.join(segmentation_dir, "report.json")
      segmentation = path |> read_json!() |> Map.put(approach, results)
      write_json!(path, segmentation)
      rebuild(dir)
    after
      Application.put_env(:nila, OpenAICompatibleChat, original_text_config)
    end
  end

  defp load_documents(dir) do
    manifest_path = Path.join(dir, "manifest.json")
    manifest = manifest_path |> read_json!() |> freeze_legacy_manifest!(manifest_path)

    Enum.map(manifest["documents"], fn name ->
      input = get_in(manifest, ["inputs", name])
      doc = input["document"]
      transcription_dir = input["transcription_attempt"]
      raw_path = Path.join(transcription_dir, "raw.json")
      raw_sha = raw_path |> File.read!() |> sha256()

      raw_sha == input["transcription_sha256"] ||
        raise "cached transcription changed for #{name}"

      {:ok, transcription} = EvalTranscription.load(transcription_dir)

      %{
        doc: doc,
        pdf: frozen_pdf!(doc),
        image_dir: Path.join([dir, "documents", name, "images"]),
        segments: decode_fixed_segments(input["fixed_segments"]),
        transcription: %{dir: transcription_dir, value: transcription},
        client_gstin: input["client_gstin"],
        portal: input["portal"]
      }
    end)
  end

  defp freeze_legacy_manifest!(%{"inputs" => inputs} = manifest, _path) when is_map(inputs),
    do: manifest

  defp freeze_legacy_manifest!(manifest, path) do
    inputs =
      Map.new(manifest["documents"], fn name ->
        doc = EvalCorpus.document!(name)
        {:ok, transcription_dir} = EvalTranscription.latest_attempt(name)
        pages = get_in(manifest, ["fixed_segments", name])

        {name,
         frozen_input(
           doc,
           pages,
           transcription_dir,
           client_gstin!(doc["client"]),
           portal_truth(doc)
         )}
      end)

    manifest = Map.put(manifest, "inputs", inputs)
    write_json!(path, manifest)
    manifest
  end

  defp frozen_pdf!(doc) do
    path = Path.join(Path.expand("~/.cache/nila/eval-corpus"), doc["key"])
    bytes = File.read!(path)

    sha256(bytes) == doc["sha256"] ||
      raise "frozen corpus PDF changed for #{doc["name"]}"

    path
  end

  defp decode_fixed_segments(pages) do
    Enum.map(pages, fn segment_pages ->
      %{
        pages: segment_pages,
        kind: :invoice,
        invoice_no: nil,
        reason: "fixed_human_boundary",
        issues: []
      }
    end)
  end

  defp segment_mistral(documents, dir, concurrency, report) do
    Map.new(documents, fn document ->
      name = document.doc["name"]
      document_dir = Path.join([dir, name, "mistral_text"])
      File.mkdir_p!(Path.join(document_dir, "raw"))
      started = System.monotonic_time(:millisecond)

      {:ok, responses} =
        PageLabels.request_all(document.transcription.value,
          kind: kind(document.doc),
          context: :paper,
          max_concurrency: concurrency,
          max_retries: 8,
          response_format: :json_schema_local,
          on_page: fn done, total ->
            report.({:comparison_segmentation_page, "mistral_text", name, done, total})
          end
        )

      Enum.each(responses, fn entry ->
        if entry[:response] do
          basename = "page_#{pad(entry.page)}"
          File.write!(Path.join(document_dir, "raw/#{basename}.json"), entry.response.body)

          write_json!(Path.join(document_dir, "raw/#{basename}.meta.json"), %{
            "page" => entry.page,
            "status" => entry.response.status,
            "retry_count" => Map.get(entry.response, :retry_count, 0),
            "usage" => response_usage(entry.response),
            "provider_request_id" => provider_request_id(entry.response.headers)
          })
        end
      end)

      result =
        case PageLabels.map_responses(responses) do
          {:ok, labels} -> segmentation_result(document, labels, elapsed(started))
          {:error, reason} -> %{"status" => "failed", "error" => inspect(reason)}
        end
        |> Map.merge(%{
          "calls" => length(responses),
          "retries" =>
            responses
            |> Enum.map(fn entry ->
              (entry[:response] && Map.get(entry.response, :retry_count, 0)) || 0
            end)
            |> Enum.sum(),
          "usage" =>
            responses
            |> Enum.flat_map(fn entry ->
              if entry[:response], do: [response_usage(entry.response)], else: []
            end)
            |> sum_usage()
        })

      write_json!(Path.join(document_dir, "result.json"), result)
      {name, result}
    end)
  end

  defp segment_qwen(documents, dir, report, approach, prompt_suffix) do
    Map.new(documents, fn document ->
      name = document.doc["name"]
      document_dir = Path.join([dir, name, approach])
      image_dir = Path.join(document_dir, "images")
      File.mkdir_p!(document_dir)
      render_segmentation_pages!(document.pdf, image_dir, document.doc["pages"])
      started = System.monotonic_time(:millisecond)
      messages = segmentation_messages(document, image_dir, prompt_suffix)

      result =
        case OpenAICompatibleChat.request_raw(
               messages,
               "nila_packet_page_labels",
               segmentation_schema(),
               max_retries: 8,
               response_format: :json_schema_local
             ) do
          {:ok, response} ->
            File.write!(Path.join(document_dir, "raw.json"), response.body)

            write_json!(Path.join(document_dir, "raw.meta.json"), %{
              "status" => response.status,
              "retry_count" => Map.get(response, :retry_count, 0),
              "usage" => response_usage(response),
              "provider_request_id" => provider_request_id(response.headers),
              "image_bytes" =>
                image_dir
                |> Path.join("page_*.jpg")
                |> Path.wildcard()
                |> Enum.map(&File.stat!(&1).size)
                |> Enum.sum()
            })

            decoded =
              case OpenAICompatibleChat.decode(response, segmentation_schema()) do
                {:ok, %{"pages" => pages}, _usage} ->
                  with {:ok, labels} <- decode_vision_labels(pages, document.doc["pages"]) do
                    segmentation_result(document, labels, elapsed(started))
                  else
                    {:error, reason} -> %{"status" => "failed", "error" => inspect(reason)}
                  end

                {:error, reason} ->
                  %{"status" => "failed", "error" => inspect(reason)}
              end

            Map.merge(decoded, %{
              "calls" => 1,
              "retries" => Map.get(response, :retry_count, 0),
              "usage" => response_usage(response)
            })

          {:error, reason} ->
            %{"status" => "failed", "error" => inspect(reason)}
        end

      write_json!(Path.join(document_dir, "result.json"), result)
      report.({:comparison_segmentation, approach, name, result["status"]})
      {name, result}
    end)
  end

  defp render_segmentation_pages!(pdf, image_dir, expected_pages) do
    File.mkdir_p!(image_dir)

    if length(Path.wildcard(Path.join(image_dir, "page_*.jpg"))) != expected_pages do
      prefix = Path.join(image_dir, "rendered")

      case System.cmd(
             "pdftoppm",
             ["-jpeg", "-jpegopt", "quality=70", "-r", "75", pdf, prefix],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, status} -> raise "pdftoppm failed (#{status}): #{output}"
      end

      rendered =
        image_dir
        |> Path.join("rendered-*.jpg")
        |> Path.wildcard()
        |> Enum.sort_by(&rendered_page_number/1)

      length(rendered) == expected_pages ||
        raise "rendered #{length(rendered)} segmentation pages, expected #{expected_pages}"

      rendered
      |> Enum.with_index(1)
      |> Enum.each(fn {source, page} -> File.rename!(source, image_path(image_dir, page)) end)
    end
  end

  defp segmentation_messages(document, image_dir, prompt_suffix) do
    intro = """
    Label every page of this ordered packet of Indian GST #{document.doc["kind"]} invoices.
    Return exactly one entry for every physical page, numbered 1 through #{document.doc["pages"]}.

    - start: this page begins a new invoice, credit note or debit note.
    - continuation: this page carries on the invoice from the preceding page.
    - non_invoice: standalone challan, e-way bill, purchase order, receipt, blank or separator.
    - unreadable: the image is too damaged to decide.
    - A repeated seller is not enough to join pages. Use document number, customer,
      explicit page numbering, continued item tables and closing totals.
    - invoice_no must be visible on that page itself; otherwise return null.
    Do not extract line items or totals. Return only the page labels.

    #{prompt_suffix}
    """

    content =
      Enum.reduce(1..document.doc["pages"], [%{type: "text", text: intro}], fn page, acc ->
        bytes = File.read!(image_path(image_dir, page))

        acc ++
          [
            %{type: "text", text: "PHYSICAL PAGE #{page}"},
            %{
              type: "image_url",
              image_url: %{url: "data:image/jpeg;base64," <> Base.encode64(bytes)}
            }
          ]
      end)

    [
      %{role: "system", content: "You split ordered invoice packets. Answer only in JSON."},
      %{role: "user", content: content}
    ]
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

  defp decode_vision_labels(pages, expected_count) do
    expected = Enum.to_list(1..expected_count)
    actual = Enum.map(pages, & &1["page"])

    if actual == expected do
      {:ok,
       Enum.map(pages, fn page ->
         %{
           page: page["page"],
           label: String.to_existing_atom(page["label"]),
           invoice_no: page["invoice_no"],
           reason: page["reason"],
           usage: %{}
         }
       end)}
    else
      {:error, {:page_conservation, expected, actual}}
    end
  end

  defp segmentation_result(document, labels, duration) do
    raw_segments = PageLabels.stitch(labels)

    {segments, violations} =
      Discovery.guard(
        document.transcription.value,
        raw_segments,
        kind: kind(document.doc)
      )

    truth = %{
      "segments" => Enum.map(document.segments, &%{"pages" => &1.pages, "kind" => "invoice"})
    }

    raw_score = Segmentation.score(raw_segments, truth)
    score = Segmentation.score(segments, truth)

    %{
      "status" => "ok",
      "duration_ms" => duration,
      "labels" => Enum.map(labels, &Map.update!(&1, :label, fn label -> to_string(label) end)),
      "segments" =>
        Enum.map(
          segments,
          &%{"pages" => &1.pages, "kind" => to_string(&1.kind), "invoice_no" => &1.invoice_no}
        ),
      "violations" => Enum.map(violations, &Discovery.describe/1),
      "raw_score" => stringify_keys(raw_score),
      "score" => stringify_keys(score)
    }
  end

  defp add_raw_segmentation_scores(segmentation, documents) do
    fixed_truth =
      Map.new(documents, fn document ->
        truth = %{
          "segments" => Enum.map(document.segments, &%{"pages" => &1.pages, "kind" => "invoice"})
        }

        {document.doc["name"], truth}
      end)

    segmentation
    |> segmentation_approaches()
    |> Enum.reduce(segmentation, fn {approach, results}, acc ->
      updated =
        Map.new(results, fn {name, result} ->
          truth = Map.fetch!(fixed_truth, name)

          labels =
            Enum.map(result["labels"] || [], fn label ->
              %{
                page: label["page"],
                label: String.to_existing_atom(label["label"]),
                invoice_no: label["invoice_no"],
                reason: label["reason"],
                usage: label["usage"] || %{}
              }
            end)

          raw_score = Segmentation.score(PageLabels.stitch(labels), truth)
          {name, Map.put(result, "raw_score", stringify_keys(raw_score))}
        end)

      Map.put(acc, approach, updated)
    end)
  end

  defp add_segmentation_operations(segmentation, dir) do
    segmentation
    |> segmentation_approaches()
    |> Enum.reduce(segmentation, fn {approach, results}, acc ->
      updated =
        Map.new(results, fn {name, result} ->
          base = Path.join([dir, "segmentation", name, approach])

          metadata =
            if approach == "mistral_text" do
              base
              |> Path.join("raw/*.meta.json")
              |> Path.wildcard()
              |> Enum.map(&read_json!/1)
            else
              path = Path.join(base, "raw.meta.json")
              if File.exists?(path), do: [read_json!(path)], else: []
            end

          operations = %{
            "calls" => length(metadata),
            "retries" => metadata |> Enum.map(&(&1["retry_count"] || 0)) |> Enum.sum(),
            "usage" => metadata |> Enum.map(&(&1["usage"] || %{})) |> sum_usage()
          }

          {name, Map.merge(result, operations)}
        end)

      Map.put(acc, approach, updated)
    end)
  end

  defp segmentation_approaches(segmentation), do: Map.drop(segmentation, ["created_at"])

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp prepare_documents(names, dir, report) do
    documents =
      Enum.map(names, fn name ->
        doc = EvalCorpus.document!(name)
        {:ok, truth} = Segmentation.truth(name)
        segments = truth_segments(truth)
        pdf = EvalCorpus.fetch!(name)
        image_dir = Path.join([dir, "documents", name, "images"])
        render_pages!(pdf, image_dir, doc["pages"])
        report.({:comparison_rendered, name, doc["pages"], length(segments)})

        transcription =
          case EvalTranscription.ensure(name) do
            {:ok, transcription_dir} ->
              {:ok, value} = EvalTranscription.load(transcription_dir)
              %{dir: transcription_dir, value: value}

            {:error, reason} ->
              throw({:prepare_failed, name, reason})
          end

        %{
          doc: doc,
          pdf: pdf,
          image_dir: image_dir,
          segments: segments,
          transcription: transcription,
          client_gstin: client_gstin!(doc["client"]),
          portal: portal_truth(doc)
        }
      end)

    {:ok, documents}
  catch
    {:prepare_failed, name, reason} -> {:error, {:prepare_failed, name, reason}}
  end

  defp truth_segments(truth) do
    truth["segments"]
    |> Enum.filter(&(&1["kind"] == "invoice"))
    |> Enum.map(fn entry ->
      %{
        pages: entry["pages"],
        kind: :invoice,
        invoice_no: nil,
        reason: entry["source"],
        issues: []
      }
    end)
  end

  defp render_pages!(pdf, image_dir, expected_pages) do
    File.mkdir_p!(image_dir)
    existing = Path.wildcard(Path.join(image_dir, "page_*.jpg"))

    if length(existing) != expected_pages do
      Enum.each(existing, &File.rm!/1)
      prefix = Path.join(image_dir, "rendered")

      case System.cmd(
             "pdftoppm",
             ["-jpeg", "-jpegopt", "quality=85", "-r", "150", pdf, prefix],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, status} -> raise "pdftoppm failed (#{status}): #{output}"
      end

      rendered =
        image_dir
        |> Path.join("rendered-*.jpg")
        |> Path.wildcard()
        |> Enum.sort_by(&rendered_page_number/1)

      length(rendered) == expected_pages ||
        raise "rendered #{length(rendered)} pages for #{pdf}, expected #{expected_pages}"

      rendered
      |> Enum.with_index(1)
      |> Enum.each(fn {source, page} ->
        File.rename!(source, image_path(image_dir, page))
      end)
    end
  end

  defp rendered_page_number(path) do
    path
    |> Path.basename(".jpg")
    |> String.split("-")
    |> List.last()
    |> String.to_integer()
  end

  defp capture_approach(approach, documents, dir, concurrency, report)
       when approach in @approaches do
    started = System.monotonic_time(:millisecond)

    results =
      Map.new(documents, fn document ->
        name = document.doc["name"]
        approach_dir = Path.join([dir, "documents", name, approach])
        File.mkdir_p!(Path.join(approach_dir, "raw"))

        rows =
          document.segments
          |> Enum.with_index(1)
          |> Task.async_stream(
            fn {segment, index} ->
              capture_segment(approach, document, segment, index, approach_dir)
            end,
            max_concurrency: concurrency,
            ordered: false,
            timeout: :infinity
          )
          |> Enum.map(fn
            {:ok, row} ->
              report.(
                {:comparison_segment, approach, name, row["index"], length(document.segments),
                 row["status"]}
              )

              row

            {:exit, reason} ->
              %{"status" => "failed", "error" => inspect(reason), "pages" => [], "index" => nil}
          end)
          |> Enum.sort_by(&(&1["index"] || 0))

        write_json!(Path.join(approach_dir, "results.json"), rows)
        {name, rows}
      end)

    result = %{
      "approach" => approach,
      "provider" => OpenAICompatibleChat.provider(),
      "model" => OpenAICompatibleChat.model(),
      "duration_ms" => System.monotonic_time(:millisecond) - started,
      "documents" => results
    }

    write_json!(Path.join(dir, "#{approach}.json"), result)
    {:ok, result}
  end

  defp capture_segment("mistral_text", document, segment, index, dir) do
    started = System.monotonic_time(:millisecond)

    case Segmented.request_segment(
           kind(document.doc),
           document.transcription.value,
           segment,
           max_retries: 8,
           response_format: :json_schema_local
         ) do
      {:ok, responses} ->
        duration = elapsed(started)
        response_meta = write_responses!(dir, index, segment.pages, responses)

        decoded =
          Enum.map(responses, fn %{response: response} ->
            OpenAICompatibleChat.decode(response, Segmented.schema(kind(document.doc)))
          end)

        case Segmented.map_segment(
               kind(document.doc),
               document.transcription.value,
               segment,
               responses,
               client_gstin: document.client_gstin
             ) do
          {:ok, artifact} ->
            raw_data = decoded_data(decoded, artifact["data"])

            {common_data, common_repairs} =
              Segmented.repair_gstins(raw_data, kind(document.doc), document.client_gstin)

            row =
              success_row(index, segment.pages, duration, response_meta, raw_data, common_data)

            row =
              Map.merge(row, %{
                "pipeline_data" => artifact["data"],
                "pipeline" => artifact,
                "common_repairs" => common_repairs
              })

            write_json!(Path.join(dir, "segment_#{pad(index)}.json"), row)
            row

          {:error, reason} ->
            failure_row(dir, index, segment.pages, duration, response_meta, reason)
        end

      {:error, reason, responses} ->
        duration = elapsed(started)
        response_meta = write_responses!(dir, index, segment.pages, responses)
        failure_row(dir, index, segment.pages, duration, response_meta, reason)
    end
  end

  defp capture_segment("qwen_vision", document, segment, index, dir) do
    started = System.monotonic_time(:millisecond)
    kind = kind(document.doc)
    messages = vision_messages(kind, segment.pages, document.image_dir)

    case OpenAICompatibleChat.request_raw(
           messages,
           "nila_direct_#{kind}_invoice",
           Segmented.schema(kind),
           max_retries: 8,
           response_format: :json_schema_local
         ) do
      {:ok, response} ->
        duration = elapsed(started)
        responses = [%{pages: segment.pages, response: response}]
        response_meta = write_responses!(dir, index, segment.pages, responses)

        case OpenAICompatibleChat.decode(response, Segmented.schema(kind)) do
          {:ok, raw_data, _usage} ->
            {common_data, common_repairs} =
              Segmented.repair_gstins(raw_data, kind, document.client_gstin)

            row =
              success_row(index, segment.pages, duration, response_meta, raw_data, common_data)

            row = Map.put(row, "common_repairs", common_repairs)
            write_json!(Path.join(dir, "segment_#{pad(index)}.json"), row)
            row

          {:error, reason} ->
            failure_row(dir, index, segment.pages, duration, response_meta, reason)
        end

      {:error, reason} ->
        failure_row(dir, index, segment.pages, elapsed(started), [], reason)
    end
  end

  defp success_row(index, pages, duration, responses, raw_data, common_data) do
    %{
      "index" => index,
      "pages" => pages,
      "status" => "ok",
      "duration_ms" => duration,
      "responses" => responses,
      "raw_data" => raw_data,
      "common_data" => common_data,
      "normalized" =>
        Gstr1.normalize_invoice(%{
          "data" => common_data,
          "page" => List.first(pages),
          "source_pages" => pages
        }),
      "checks" => deterministic_checks(common_data)
    }
  end

  defp failure_row(dir, index, pages, duration, responses, reason) do
    row = %{
      "index" => index,
      "pages" => pages,
      "status" => "failed",
      "duration_ms" => duration,
      "responses" => responses,
      "error" => inspect(reason, limit: 20, printable_limit: 2_000)
    }

    write_json!(Path.join(dir, "segment_#{pad(index)}.json"), row)
    row
  end

  defp write_responses!(dir, index, segment_pages, responses) do
    responses
    |> Enum.with_index()
    |> Enum.map(fn {%{pages: pages, response: response}, chunk} ->
      basename = "seg_#{pad(index)}_chunk_#{chunk}"
      relative = Path.join("raw", "#{basename}.json")
      File.write!(Path.join(dir, relative), response.body)

      meta = %{
        "segment_pages" => segment_pages,
        "chunk_pages" => pages,
        "status" => response.status,
        "provider_request_id" => provider_request_id(response.headers),
        "usage" => response_usage(response),
        "retry_count" => Map.get(response, :retry_count, 0),
        "response_sha256" => sha256(response.body),
        "raw_path" => relative
      }

      write_json!(Path.join(dir, "raw/#{basename}.meta.json"), meta)
      meta
    end)
  end

  defp decoded_data([{:ok, data, _usage}], _fallback), do: data
  defp decoded_data(_chunks, fallback), do: fallback

  defp vision_messages(kind, pages, image_dir) do
    page_list = Enum.join(pages, ", ")

    instruction =
      Segmented.prompt(kind)
      |> String.replace("OCR text", "page images")
      |> Kernel.<>("""

      These are physical PDF pages #{page_list}, in order. Read the pixels directly.
      Before choosing a numeric value, reconcile ambiguous decimal placement and
      separate rupee/paise columns against the printed totals and amount in words.
      Do not scale a whole invoice merely because faint column boundaries resemble
      decimal points. Reconciliation may disambiguate a visible value; it must not
      invent a value that is absent.
      """)

    images =
      Enum.map(pages, fn page ->
        bytes = File.read!(image_path(image_dir, page))

        %{
          type: "image_url",
          image_url: %{url: "data:image/jpeg;base64," <> Base.encode64(bytes)}
        }
      end)

    [
      %{
        role: "system",
        content: "You read invoices from page images into JSON. Answer only in JSON."
      },
      %{role: "user", content: [%{type: "text", text: instruction} | images]}
    ]
  end

  defp build_comparison(documents, mistral, qwen, dir) do
    document_reports =
      Map.new(documents, fn document ->
        name = document.doc["name"]
        left = mistral["documents"][name]
        right = qwen["documents"][name]
        portal = document.portal

        rows =
          Enum.map(document.segments |> Enum.with_index(1), fn {segment, index} ->
            baseline = Enum.find(left, &(&1["index"] == index))
            vision = Enum.find(right, &(&1["index"] == index))
            expected = expected_for(portal, baseline, vision)

            %{
              "index" => index,
              "pages" => segment.pages,
              "mistral_text" => baseline,
              "qwen_vision" => vision,
              "portal" => expected,
              "fields" => comparison_fields(baseline, vision, expected),
              "images" =>
                Enum.map(segment.pages, fn page ->
                  Path.relative_to(image_path(document.image_dir, page), dir)
                end)
            }
          end)

        {name,
         %{
           "document" => document.doc,
           "transcription_attempt" => document.transcription.dir,
           "ocr" => read_json!(Path.join(document.transcription.dir, "meta.json")),
           "segments" => rows,
           "mistral_text" => approach_summary(left, mistral, rows, "mistral_text"),
           "qwen_vision" => approach_summary(right, qwen, rows, "qwen_vision")
         }}
      end)

    %{
      "created_at" => stamp(),
      "dir" => dir,
      "documents" => document_reports,
      "mistral_text" => Map.drop(mistral, ["documents"]),
      "qwen_vision" => Map.drop(qwen, ["documents"])
    }
  end

  defp approach_summary(results, approach, segment_rows, approach_name) do
    successful = Enum.filter(results, &(&1["status"] == "ok"))
    durations = Enum.map(successful, & &1["duration_ms"])
    usages = successful |> Enum.flat_map(& &1["responses"]) |> Enum.map(& &1["usage"])
    fields = ~w(invoice_number invoice_date seller_gstin buyer_gstin taxable tax grand_total)

    correctness =
      Map.new(fields, fn field ->
        compared =
          for row <- segment_rows,
              value = Enum.find(row["fields"], &(&1["field"] == field)),
              not is_nil(value["portal"]),
              do: value

        correct =
          Enum.count(compared, fn value ->
            comparison_equal?(field, value[approach_name], value["portal"])
          end)

        {field, %{"correct" => correct, "compared" => length(compared)}}
      end)

    invoice_score = correctness["invoice_number"]

    %{
      "provider" => approach["provider"],
      "model" => approach["model"],
      "successful" => length(successful),
      "failed" => length(results) - length(successful),
      "portal_aligned_segments" => invoice_score["compared"],
      "portal_invoice_matches" => invoice_score["correct"],
      "duration_ms" => latency(durations),
      "usage" => sum_usage(usages),
      "field_correctness" => correctness,
      "flagged" => Enum.count(successful, &(&1["checks"] != []))
    }
  end

  defp expected_for(portal, baseline, vision) do
    left = portal_for_data(portal, result_data(baseline))
    right = portal_for_data(portal, result_data(vision))

    case {left, right} do
      {nil, expected} -> expected
      {expected, nil} -> expected
      {%{"invoice_number" => number}, %{"invoice_number" => number}} -> left
      {_different_left, _different_right} -> nil
    end
  end

  defp portal_for_data(_portal, nil), do: nil

  defp portal_for_data(portal, data) do
    Map.get(portal, invoice_key(data["invoice_number"]))
  end

  defp result_data(%{"status" => "ok"} = row), do: row["common_data"]
  defp result_data(_row), do: nil

  defp comparison_fields(baseline, vision, truth) do
    fields = [
      {"invoice_number", & &1["invoice_number"]},
      {"invoice_date", & &1["invoice_date"]},
      {"seller_gstin", &get_in(&1, ["seller", "gstin"])},
      {"buyer_gstin", &get_in(&1, ["buyer", "gstin"])},
      {"taxable", &accounting_values(&1)["taxable"]},
      {"tax", &accounting_values(&1)["tax"]},
      {"grand_total", &accounting_values(&1)["grand_total"]},
      {"line_count", &length(&1["line_items"] || [])}
    ]

    Enum.map(fields, fn {name, getter} ->
      left = result_data(baseline)
      right = result_data(vision)
      expected = truth && truth[name]

      %{
        "field" => name,
        "mistral_text" => left && getter.(left),
        "qwen_vision" => right && getter.(right),
        "portal" => expected,
        "models_agree" => comparison_equal?(name, left && getter.(left), right && getter.(right))
      }
    end)
  end

  defp accounting_values(data) do
    lines = data["line_items"] || []

    taxable =
      data["printed_total_taxable"] ||
        complete_sum(lines, fn line ->
          line["printed_taxable_value"] ||
            if(line["line_amount_tax_inclusion"] == "exclusive", do: line["printed_line_amount"])
        end)

    tax =
      data["printed_total_tax"] ||
        sum_present([data["printed_cgst"], data["printed_sgst"], data["printed_igst"]]) ||
        complete_sum(lines, fn line ->
          sum_present([line["cgst_amount"], line["sgst_amount"], line["igst_amount"]])
        end)

    %{
      "taxable" => taxable,
      "tax" => tax,
      "grand_total" => data["printed_grand_total"]
    }
  end

  defp complete_sum([], _fun), do: nil

  defp complete_sum(values, fun) do
    mapped = Enum.map(values, fun)
    if Enum.all?(mapped, &is_number/1), do: Enum.sum(mapped), else: nil
  end

  defp sum_present(values) do
    present = Enum.filter(values, &is_number/1)
    if present == [], do: nil, else: Enum.sum(present)
  end

  defp deterministic_checks(data) do
    values = accounting_values(data)
    gstins = [get_in(data, ["seller", "gstin"]), get_in(data, ["buyer", "gstin"])]

    gstin_flags =
      gstins
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&Nila.Gstin.valid?/1)
      |> Enum.map(&%{"check" => "invalid_gstin", "value" => &1})

    arithmetic =
      if Enum.all?([values["taxable"], values["tax"], values["grand_total"]], &is_number/1) do
        adjustment =
          Enum.sum([
            data["printed_additional_charges"] || 0,
            data["printed_rounding_adjustment"] || 0,
            -(data["printed_discount_amount"] || 0)
          ])

        difference = values["taxable"] + values["tax"] + adjustment - values["grand_total"]

        if abs(difference) > 0.02,
          do: [
            %{"check" => "invoice_arithmetic", "difference" => Float.round(difference * 1.0, 2)}
          ],
          else: []
      else
        []
      end

    gstin_flags ++ arithmetic
  end

  defp portal_truth(doc) do
    path = portal_path(doc)

    if path do
      path
      |> File.read!()
      |> Jason.decode!()
      |> collect_portal_invoices(%{}, kind(doc), client_gstin!(doc["client"]))
      |> Map.new(fn invoice -> {invoice_key(invoice["invoice_number"]), invoice} end)
    else
      %{}
    end
  end

  defp portal_path(%{"kind" => "sales", "ground_truth" => path}), do: path

  defp portal_path(%{"kind" => "purchase", "client" => client, "period" => period}) do
    Path.wildcard("test/fixtures/purchase/#{client}/#{period}/returns_R2B_*.json") |> List.first()
  end

  defp collect_portal_invoices(value, context, kind, client_gstin) when is_list(value) do
    Enum.flat_map(value, &collect_portal_invoices(&1, context, kind, client_gstin))
  end

  defp collect_portal_invoices(value, context, kind, client_gstin) when is_map(value) do
    context =
      if is_binary(value["ctin"]), do: Map.put(context, "ctin", value["ctin"]), else: context

    if is_binary(value["inum"]) do
      details = collect_item_details(value["itms"] || [])

      taxable =
        value["txval"] ||
          details |> Enum.map(& &1["txval"]) |> Enum.filter(&is_number/1) |> Enum.sum()

      direct_tax = Enum.map(~w(cgst sgst igst cess), &value[&1])

      tax =
        if Enum.any?(direct_tax, &is_number/1) do
          direct_tax |> Enum.filter(&is_number/1) |> Enum.sum()
        else
          details
          |> Enum.flat_map(&[&1["camt"], &1["samt"], &1["iamt"], &1["csamt"]])
          |> Enum.filter(&is_number/1)
          |> Enum.sum()
        end

      [
        %{
          "invoice_number" => value["inum"],
          "invoice_date" => value["idt"] || value["dt"],
          "seller_gstin" => if(kind == :sales, do: client_gstin, else: context["ctin"]),
          "buyer_gstin" => if(kind == :sales, do: context["ctin"], else: client_gstin),
          "taxable" => taxable,
          "tax" => tax,
          "grand_total" => value["val"]
        }
      ]
    else
      Enum.flat_map(value, fn {_key, child} ->
        collect_portal_invoices(child, context, kind, client_gstin)
      end)
    end
  end

  defp collect_portal_invoices(_value, _context, _kind, _client_gstin), do: []

  defp collect_item_details(value) when is_list(value),
    do: Enum.flat_map(value, &collect_item_details/1)

  defp collect_item_details(%{"itm_det" => detail}) when is_map(detail), do: [detail]

  defp collect_item_details(value) when is_map(value),
    do: Enum.flat_map(value, fn {_key, child} -> collect_item_details(child) end)

  defp collect_item_details(_value), do: []

  defp comparison_equal?("invoice_date", left, right),
    do: field_equal?(normalize_date(left), normalize_date(right))

  defp comparison_equal?(field, left, right) when field in ~w(seller_gstin buyer_gstin),
    do: normalize_gstin(left) == normalize_gstin(right)

  defp comparison_equal?(_field, left, right), do: field_equal?(left, right)

  defp field_equal?(left, right) when is_number(left) and is_number(right),
    do: abs(left - right) <= 0.02

  defp field_equal?(left, right), do: normalized_scalar(left) == normalized_scalar(right)

  defp normalize_date(nil), do: nil

  defp normalize_date(value) do
    case Gstr1.normalize_invoice(%{"invoice_date" => value})["invoice_date"] do
      %Date{} = date -> date
      unparsed -> parse_named_date(unparsed)
    end
  end

  defp parse_named_date(value) when is_binary(value) do
    case Regex.run(~r/^(\d{1,2})[\s\/-]+([A-Za-z]+)[\s\/-]+(\d{2}|\d{4})$/, value) do
      [_, day, month, year] ->
        with month when is_integer(month) <- month_number(month),
             year <- normalize_year(String.to_integer(year)),
             {:ok, date} <- Date.new(year, month, String.to_integer(day)) do
          date
        else
          _invalid -> value
        end

      _unparsed ->
        value
    end
  end

  defp parse_named_date(value), do: value

  defp month_number(value) do
    Map.get(
      %{
        "JAN" => 1,
        "JANUARY" => 1,
        "FEB" => 2,
        "FEBRUARY" => 2,
        "MAR" => 3,
        "MARCH" => 3,
        "APR" => 4,
        "APRIL" => 4,
        "MAY" => 5,
        "JUN" => 6,
        "JUNE" => 6,
        "JUL" => 7,
        "JULY" => 7,
        "AUG" => 8,
        "AUGUST" => 8,
        "SEP" => 9,
        "SEPT" => 9,
        "SEPTEMBER" => 9,
        "OCT" => 10,
        "OCTOBER" => 10,
        "NOV" => 11,
        "NOVEMBER" => 11,
        "DEC" => 12,
        "DECEMBER" => 12
      },
      String.upcase(value)
    )
  end

  defp normalize_year(year) when year < 100, do: year + 2000
  defp normalize_year(year), do: year

  defp normalize_gstin(nil), do: nil

  defp normalize_gstin(value) do
    value |> to_string() |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")
  end

  defp normalized_scalar(nil), do: nil
  defp normalized_scalar(%Date{} = date), do: Date.to_iso8601(date)

  defp normalized_scalar(value) when is_binary(value) do
    String.upcase(String.replace(value, ~r/\s+/, ""))
  end

  defp normalized_scalar(value), do: value

  defp invoice_key(nil), do: nil
  defp invoice_key(value), do: value |> to_string() |> normalized_scalar()

  defp latency([]), do: nil

  defp latency(values) do
    sorted = Enum.sort(values)

    %{
      "min" => List.first(sorted),
      "p50" => Enum.at(sorted, max(ceil(length(sorted) * 0.50) - 1, 0)),
      "p95" => Enum.at(sorted, max(ceil(length(sorted) * 0.95) - 1, 0)),
      "max" => List.last(sorted)
    }
  end

  defp sum_usage(usages), do: Segmented.sum_usage(usages)

  defp write_reports!(dir, comparison) do
    write_json!(Path.join(dir, "report.json"), comparison)
    File.write!(Path.join(dir, "report.md"), markdown(comparison))
    File.write!(Path.join(dir, "report.html"), html(comparison))
  end

  defp markdown(report) do
    documents =
      Enum.map_join(report["documents"], "\n", fn {name, doc} ->
        left = doc["mistral_text"]
        right = doc["qwen_vision"]

        """
        ## #{name}

        OCR: #{doc["ocr"]["duration_ms"]}ms for #{doc["ocr"]["pages"]} pages (separate from extraction metrics).

        | Approach | Success | Invoice no. exact | Flagged | p50 | p95 | Tokens | Cost |
        |---|---:|---:|---:|---:|---:|---:|---:|
        | Mistral OCR → Small | #{left["successful"]} | #{left["portal_invoice_matches"]}/#{left["portal_aligned_segments"]} | #{left["flagged"]} | #{latency_value(left, "p50")} | #{latency_value(left, "p95")} | #{usage(left, "total_tokens")} | #{usage(left, "cost")} |
        | Qwen direct vision | #{right["successful"]} | #{right["portal_invoice_matches"]}/#{right["portal_aligned_segments"]} | #{right["flagged"]} | #{latency_value(right, "p50")} | #{latency_value(right, "p95")} | #{usage(right, "total_tokens")} | #{usage(right, "cost")} |

        #{correctness_markdown(left, right)}
        """
      end)

    """
    # Direct vision comparison

    Generated #{report["created_at"]}. Full visual report: `report.html`.

    Extraction-only batch wall time: Mistral Small #{report["mistral_text"]["duration_ms"]}ms; Qwen direct vision #{report["qwen_vision"]["duration_ms"]}ms. Mistral OCR is reported separately per document and is not included in the Small timing, tokens, or cost.

    Portal-aligned rows use an invoice number produced by either model only when the other model does not map to a different portal invoice. Invoice-number exactness is scored explicitly; segments with no unambiguous portal row remain visual-review rows.

    #{documents}
    #{segmentation_markdown(report["segmentation"])}
    """
  end

  defp correctness_markdown(left, right) do
    rows =
      Enum.map_join(
        ~w(invoice_number invoice_date seller_gstin buyer_gstin taxable tax grand_total),
        "\n",
        fn field ->
          left_score = left["field_correctness"][field]
          right_score = right["field_correctness"][field]

          "| #{field} | #{left_score["correct"]}/#{left_score["compared"]} | #{right_score["correct"]}/#{right_score["compared"]} |"
        end
      )

    """
    | Portal-aligned field | Mistral OCR → Small | Qwen direct vision |
    |---|---:|---:|
    #{rows}
    """
  end

  defp segmentation_markdown(nil), do: ""

  defp segmentation_markdown(segmentation) do
    rows =
      for {approach, results} <- segmentation_approaches(segmentation),
          {name, result} <- results do
        raw_score = result["raw_score"] || %{}
        score = result["score"] || %{}

        "| #{approach} | #{name} | #{raw_score["boundary_f1"] || "-"} | #{score["boundary_f1"] || "-"} | #{score["kind_accuracy"] || "-"} | #{result["calls"] || "-"} | #{result["retries"] || 0} | #{result["duration_ms"] || "-"} | #{get_in(result, ["usage", "total_tokens"]) || "-"} | #{get_in(result, ["usage", "cost"]) || "-"} |"
      end
      |> Enum.join("\n")

    """

    ## Segmentation

    The duplicate-rule variants are post-hoc generic prompt corrections after the first Qwen run merged two complete duplicate scans. The first corrected run split them; an immediate repeat merged them again, so the corrected prompt is not stable.

    | Approach | Document | Raw boundary F1 | Guarded boundary F1 | Kind accuracy | Calls | Retries | Duration ms | Tokens | Cost |
    |---|---|---:|---:|---:|---:|---:|---:|---:|---:|
    #{rows}
    """
  end

  defp html(report) do
    sections =
      Enum.map_join(report["documents"], "\n", fn {name, doc} ->
        rows = Enum.map_join(doc["segments"], "\n", &segment_html(&1, report["dir"], name))
        "<section><h2>#{escape(name)}</h2>#{summary_html(doc)}#{rows}</section>"
      end)

    """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Nila vision comparison</title>
    <style>
    :root{color-scheme:light dark}body{font:14px system-ui;margin:24px;max-width:1800px}table{border-collapse:collapse;width:100%;margin:12px 0}th,td{border:1px solid #8886;padding:6px;text-align:left;vertical-align:top}.segment{border:1px solid #8888;border-radius:8px;margin:18px 0;padding:14px}.images{display:flex;gap:10px;overflow:auto}.images img{max-height:700px;max-width:48%;object-fit:contain;border:1px solid #8886}.models{display:grid;grid-template-columns:1fr 1fr;gap:12px}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#8881;padding:10px;max-height:520px;overflow:auto}.agree{opacity:.72}.different{background:#d98b1830}.wrong{background:#d9302530}.ok{background:#18803825}.failed{color:#d93025}details{margin-top:8px}.summary{max-width:1100px}@media(max-width:900px){.models{grid-template-columns:1fr}.images img{max-width:95%}}
    </style></head><body>
    <h1>Nila: Mistral OCR → Small vs Qwen direct vision</h1>
    <p>Generated #{escape(report["created_at"])}. Fixed human-reviewed page boundaries; one extraction pass per approach.</p>
    <p>Extraction-only batch wall time: Mistral Small #{report["mistral_text"]["duration_ms"]}ms; Qwen direct vision #{report["qwen_vision"]["duration_ms"]}ms. OCR is reported separately per document.</p>
    <p>Portal alignment uses a number produced by either model only when the other model does not map to a different portal invoice. Invoice-number exactness is scored; unaligned segments remain for visual review.</p>
    #{segmentation_html(report["segmentation"])}
    #{sections}
    </body></html>
    """
  end

  defp segmentation_html(nil), do: ""

  defp segmentation_html(segmentation) do
    rows =
      for {approach, results} <- segmentation_approaches(segmentation),
          {name, result} <- results do
        raw_score = result["raw_score"] || %{}
        score = result["score"] || %{}

        "<tr><td>#{escape(approach)}</td><td>#{escape(name)}</td><td>#{escape(raw_score["boundary_f1"] || "-")}</td><td>#{escape(score["boundary_f1"] || "-")}</td><td>#{escape(score["kind_accuracy"] || "-")}</td><td>#{escape(result["calls"] || "-")}</td><td>#{escape(result["retries"] || 0)}</td><td>#{escape(result["duration_ms"] || "-")}</td><td>#{escape(get_in(result, ["usage", "total_tokens"]) || "-")}</td><td>#{escape(get_in(result, ["usage", "cost"]) || "-")}</td><td>#{escape(inspect(result["segments"] || []))}</td></tr>"
      end
      |> Enum.join()

    """
    <section><h2>Segmentation</h2><p>The duplicate-rule variants are post-hoc. Their two purchase runs disagreed about the complete duplicate scans, so the correction is not stable.</p><table><thead><tr><th>Approach</th><th>Document</th><th>Raw boundary F1</th><th>Guarded boundary F1</th><th>Kind accuracy</th><th>Calls</th><th>Retries</th><th>Duration ms</th><th>Tokens</th><th>Cost</th><th>Proposed segments</th></tr></thead><tbody>#{rows}</tbody></table></section>
    """
  end

  defp summary_html(doc) do
    left = doc["mistral_text"]
    right = doc["qwen_vision"]

    """
    <p>OCR: #{doc["ocr"]["duration_ms"]}ms for #{doc["ocr"]["pages"]} pages; excluded from extraction latency, tokens and cost below.</p>
    <table class="summary"><thead><tr><th>Approach</th><th>Success</th><th>Invoice no. exact</th><th>Flagged</th><th>p50</th><th>p95</th><th>Tokens</th><th>Cost</th></tr></thead><tbody>
    <tr><td>Mistral OCR → Small</td><td>#{left["successful"]}/#{left["successful"] + left["failed"]}</td><td>#{left["portal_invoice_matches"]}/#{left["portal_aligned_segments"]}</td><td>#{left["flagged"]}</td><td>#{latency_value(left, "p50")}ms</td><td>#{latency_value(left, "p95")}ms</td><td>#{usage(left, "total_tokens")}</td><td>#{usage(left, "cost")}</td></tr>
    <tr><td>Qwen direct vision</td><td>#{right["successful"]}/#{right["successful"] + right["failed"]}</td><td>#{right["portal_invoice_matches"]}/#{right["portal_aligned_segments"]}</td><td>#{right["flagged"]}</td><td>#{latency_value(right, "p50")}ms</td><td>#{latency_value(right, "p95")}ms</td><td>#{usage(right, "total_tokens")}</td><td>#{usage(right, "cost")}</td></tr>
    </tbody></table>
    #{correctness_html(left, right)}
    """
  end

  defp correctness_html(left, right) do
    rows =
      Enum.map_join(
        ~w(invoice_number invoice_date seller_gstin buyer_gstin taxable tax grand_total),
        "",
        fn field ->
          left_score = left["field_correctness"][field]
          right_score = right["field_correctness"][field]

          "<tr><td>#{escape(field)}</td><td>#{left_score["correct"]}/#{left_score["compared"]}</td><td>#{right_score["correct"]}/#{right_score["compared"]}</td></tr>"
        end
      )

    "<table class=\"summary\"><thead><tr><th>Portal-aligned field</th><th>Mistral OCR → Small</th><th>Qwen direct vision</th></tr></thead><tbody>#{rows}</tbody></table>"
  end

  defp segment_html(row, root, name) do
    fields =
      Enum.map_join(row["fields"], "", fn field ->
        class = field_class(field)

        "<tr class=\"#{class}\"><td>#{escape(field["field"])}</td><td>#{escape(inspect(field["mistral_text"]))}</td><td>#{escape(inspect(field["qwen_vision"]))}</td><td>#{escape(inspect(field["portal"]))}</td></tr>"
      end)

    images =
      Enum.map_join(row["images"], "", fn path ->
        "<a href=\"#{escape(path)}\"><img loading=\"lazy\" src=\"#{escape(path)}\"></a>"
      end)

    """
    <article class="segment"><h3>Pages #{Enum.join(row["pages"], ", ")}</h3>
    <div class="images">#{images}</div>
    <table><thead><tr><th>Field</th><th>Mistral OCR → Small</th><th>Qwen vision</th><th>Portal</th></tr></thead><tbody>#{fields}</tbody></table>
    <div class="models">#{result_html(row["mistral_text"], root, name, "mistral_text")}#{result_html(row["qwen_vision"], root, name, "qwen_vision")}</div>
    </article>
    """
  end

  defp result_html(%{"status" => "ok"} = row, root, name, approach) do
    links =
      Enum.map_join(row["responses"], " ", fn response ->
        absolute = Path.join([root, "documents", name, approach, response["raw_path"]])
        path = Path.relative_to(absolute, root)
        "<a href=\"#{escape(path)}\">raw response</a>"
      end)

    """
    <div><h4>#{escape(approach)} — #{row["duration_ms"]}ms</h4><p>#{links}</p>
    <p>Checks: #{escape(inspect(row["checks"]))}</p>
    <details><summary>Extracted JSON</summary><pre>#{escape(Jason.encode!(row["common_data"], pretty: true))}</pre></details>
    <details><summary>Raw model JSON</summary><pre>#{escape(Jason.encode!(row["raw_data"], pretty: true))}</pre></details></div>
    """
  end

  defp result_html(row, _root, _name, approach) do
    "<div class=\"failed\"><h4>#{escape(approach)} failed</h4><pre>#{escape((row && row["error"]) || "missing result")}</pre></div>"
  end

  defp field_class(%{"portal" => portal} = field) when not is_nil(portal) do
    left = comparison_equal?(field["field"], field["mistral_text"], portal)
    right = comparison_equal?(field["field"], field["qwen_vision"], portal)
    if left and right, do: "ok", else: "wrong"
  end

  defp field_class(%{"models_agree" => true}), do: "agree"
  defp field_class(_field), do: "different"

  defp latency_value(summary, key), do: get_in(summary, ["duration_ms", key]) || "-"
  defp usage(summary, key), do: get_in(summary, ["usage", key]) || "-"

  defp write_manifest(dir, documents, concurrency, qwen_config) do
    fixed_segments =
      Map.new(
        documents,
        &{&1.doc["name"], Enum.map(&1.segments, fn segment -> segment.pages end)}
      )

    inputs =
      Map.new(documents, fn document ->
        name = document.doc["name"]

        {name,
         frozen_input(
           document.doc,
           fixed_segments[name],
           document.transcription.dir,
           document.client_gstin,
           document.portal
         )}
      end)

    write_json!(Path.join(dir, "manifest.json"), %{
      "documents" => Enum.map(documents, & &1.doc["name"]),
      "fixed_segments" => fixed_segments,
      "inputs" => inputs,
      "concurrency" => concurrency,
      "mistral_model" => "mistral-small-latest",
      "qwen_provider" => qwen_config[:provider],
      "qwen_model" => qwen_config[:model],
      "created_at" => stamp()
    })

    :ok
  end

  defp frozen_input(doc, fixed_segments, transcription_dir, client_gstin, portal) do
    %{
      "document" => doc,
      "fixed_segments" => fixed_segments,
      "transcription_attempt" => transcription_dir,
      "transcription_sha256" =>
        transcription_dir |> Path.join("raw.json") |> File.read!() |> sha256(),
      "client_gstin" => client_gstin,
      "portal" => portal
    }
  end

  defp mistral_text_config(original) do
    ocr = Application.get_env(:nila, Mistral, [])

    original
    |> Keyword.put(:provider, "mistral")
    |> Keyword.put(
      :base_url,
      String.trim_trailing(ocr[:base_url] || "https://api.mistral.ai", "/") <> "/v1"
    )
    |> Keyword.put(:api_key, ocr[:api_key])
    |> Keyword.put(:model, "mistral-small-latest")
    |> Keyword.put(:response_format, :json_schema)
    |> Keyword.delete(:provider_options)
  end

  defp with_text_config(config, fun) do
    Application.put_env(:nila, OpenAICompatibleChat, config)
    fun.()
  end

  defp client_gstin!(client) do
    Enum.find_value(EvalCorpus.clients(), fn {gstin, name} -> if name == client, do: gstin end) ||
      raise "no corpus GSTIN for #{client}"
  end

  defp kind(%{"kind" => "sales"}), do: :sales
  defp kind(%{"kind" => "purchase"}), do: :purchase

  defp image_path(dir, page), do: Path.join(dir, "page_#{pad(page)}.jpg")
  defp pad(value), do: value |> to_string() |> String.pad_leading(3, "0")
  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  defp response_usage(response) do
    case Jason.decode(response.body) do
      {:ok, %{"usage" => usage}} when is_map(usage) -> usage
      _missing -> %{}
    end
  end

  defp provider_request_id(headers) do
    Enum.find_value(["x-request-id", "x-ai-gateway-request-id", "x-vercel-id"], fn name ->
      case Map.get(headers, name, []) do
        [value | _rest] -> value
        value when is_binary(value) -> value
        _missing -> nil
      end
    end)
  end

  defp sha256(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true))
  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp escape(nil), do: ""

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp attempt_id, do: Eval.run_id()
  defp stamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
