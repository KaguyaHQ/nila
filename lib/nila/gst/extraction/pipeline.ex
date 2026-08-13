defmodule Nila.Gst.Extraction.Pipeline do
  @moduledoc """
  Reads a packet by cutting it into bills first and extracting one bill at a time.

  This is the production read. It replaces the former window-based reader
  because page chunks were a transport decision doing a semantic job:
  `/v1/ocr` fuses transcription and annotation into a single call,
  only the annotation half has a per-call output budget, and a dense chunk spent
  one budget across several bills. The same 10-row invoice came back complete
  read alone and 8 rows long inside an 8-page chunk — with HTTP 200 either way.
  Shrinking the chunk reduced the odds; it could not remove them, because
  the unit of extraction was never the unit of correctness.

  Three stages, each with its own failure and its own measurement:

      transcribe   one OCR call, annotation off   → one text per physical page
      discover     one small call per page        → segments, one per bill
      extract      one call per segment           → one invoice, grounded

  Every number a bill prints must be findable in that bill's own transcribed
  text (`Nila.Gst.Extraction.Verify`), which is the check the fused call could
  not offer: there was no text to search, only pixels and an answer.

  ## A bill that will not read

  Provider and transport failures are infrastructure state, never document
  semantics. Every page label and invoice segment must return successfully before
  this pipeline publishes a result. A successful model verdict of `unreadable`
  still leaves that page in `:unaccounted_pages` for human review; an exhausted
  429 cannot manufacture that verdict or publish a partial month.

  ## Audit

  One attempt row per stage rather than per call. A 57-page packet is 1 + 57 + 55
  provider calls, and a row apiece would bury the three facts a reviewer actually
  wants — did the scan read, did it segment, did the bills come back. Token usage
  is summed per stage; the transcription's raw response is kept whole because it
  is the text every later stage and every grounding check was run against.
  """

  alias Nila.Gst.Extraction.Discovery
  alias Nila.Gst.Extraction.Evidence
  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Extraction.Providers.MistralChat
  alias Nila.Gst.Extraction.Segmented
  alias Nila.Gst.Extraction.Transcription

  require Logger

  @typedoc """
  One `:on_progress` report. `stage` names which of the three is running, because
  the honest unit changes with it: pages while the packet is being labelled,
  bills while they are being read.
  """
  @type progress ::
          %{stage: :transcribing, done: 0, total: 1}
          | %{
              stage: :segmenting,
              done: non_neg_integer(),
              total: pos_integer(),
              pages_done: non_neg_integer(),
              page_count: pos_integer()
            }
          | %{stage: :reading, done: non_neg_integer(), total: non_neg_integer()}

  @doc """
  Packet in, verified invoices out, in the shared extraction-result shape used
  by normalization, the workbench and eval.

  Options: `:filename` (content type and evidence rendering), `:client_gstin`
  (the client's own number — repairs their own side of a bill and is discounted
  when counting a segment's counterparties), `:per_call` (wraps each stage for
  the audit row) and `:on_progress` (progress).
  """
  def extract(kind, bytes, opts \\ []) when kind in [:purchase, :sales] and is_binary(bytes) do
    hooks = %{
      per_call: Keyword.get(opts, :per_call) || (&call_through/2),
      on_progress: Keyword.get(opts, :on_progress) || (&ignore_progress/1)
    }

    # `:pages` and `:page_numbers` would transcribe a subset while the evidence
    # renderer still rasterizes the whole packet, so they stop at this boundary.
    provider_opts = Keyword.drop(opts, [:per_call, :on_progress, :pages, :page_numbers])

    with {:ok, transcription} <- transcribe(bytes, provider_opts, hooks) do
      # Told to us in production, inferred from the packet otherwise, and
      # resolved once so the guards and the repairs cannot disagree about who
      # the client is.
      client = provider_opts[:client_gstin] || Discovery.client_gstin(transcription)
      provider_opts = Keyword.put(provider_opts, :client_gstin, client)

      with {:ok, discovery} <- discover(kind, transcription, provider_opts, hooks),
           {:ok, result} <- read_segments(kind, transcription, discovery, provider_opts, hooks) do
        {:ok, Evidence.attach(result, bytes, provider_opts)}
      else
        # A stage reports its audit alongside the reason so the attempt row can
        # be closed with it; the caller asked for invoices and gets one shape.
        {:error, reason, _audit} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ---- transcribe ----

  defp transcribe(bytes, opts, hooks) do
    report(hooks, %{stage: :transcribing, done: 0, total: 1})

    with {:ok, opts} <- shared_document(bytes, opts) do
      try do
        case attempt_transcription(bytes, opts, hooks, 1) do
          {:ok, %{transcription: transcription}} -> {:ok, transcription}
          {:error, reason} -> {:error, reason}
          {:error, reason, _audit} -> {:error, reason}
        end
      after
        delete_upload(opts)
      end
    end
  end

  # One retry, and only for what a retry can fix. Mistral caches OCR on identical
  # document bytes, so a resend after a client timeout lands in seconds — the
  # former reader measured this and relied on it; the segmented path keeps that
  # recovery rather than turning one slow response into a failed month.
  defp attempt_transcription(bytes, opts, hooks, try_number) do
    result = hooks.per_call.(%{stage: "transcription"}, fn -> transcription_call(bytes, opts) end)

    with {:error, _reason} <- normalize_error(result),
         true <- try_number == 1 and retryable?(reason(result)) do
      Logger.warning("segmented_extraction.transcription_retry reason=#{inspect(reason(result))}")
      # The page count is not known until the scan comes back, so the retry
      # narrates the whole packet rather than a range.
      hooks.on_progress.({:retrying, "all"})
      attempt_transcription(bytes, opts, hooks, try_number + 1)
    else
      _no_retry -> result
    end
  end

  defp transcription_call(bytes, opts) do
    case Mistral.transcribe_raw(bytes, opts) do
      {:ok, %{status: status, body: body} = response} when status in 200..299 ->
        with {:ok, transcription} <- Transcription.from_response(body) do
          {:ok,
           %{
             transcription: transcription,
             audit: transcription_audit(response, Transcription.page_count(transcription))
           }}
        end

      {:ok, response} ->
        {:error, {:mistral_ocr_failed, response.status, error_body(response)},
         %{http_status: response.status, provider: Mistral.provider(), model: Mistral.model()}}

      {:error, reason, audit} ->
        {:error, reason, audit}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transcription_audit(response, page_count) do
    %{
      provider: Mistral.provider(),
      model: Mistral.model(),
      http_status: response.status,
      provider_request_id: request_id(response.headers),
      source_page_count: page_count,
      # The billed unit for OCR is the page, and it is the one usage figure this
      # stage has; dropping it would leave cost-per-dump underivable from the
      # audit table.
      usage: usage_info(response.body),
      raw_response: response.body
    }
  end

  defp usage_info(body) do
    case Jason.decode(body) do
      {:ok, %{"usage_info" => usage}} when is_map(usage) -> usage
      _no_usage -> %{}
    end
  end

  # Inlining base64s the packet into the request body, and base64's 4/3 expansion
  # caps an inlined document at ~37.5 MB against the API's 50 MB limit — a large
  # shoebox would be refused for size after a minute of work. Anything near that
  # is uploaded once and referenced; an upload that fails degrades to inlining
  # rather than failing the read, and says so.
  @inline_limit 20_000_000

  defp shared_document(bytes, opts) do
    if byte_size(bytes) > @inline_limit and share_document?() do
      case Mistral.upload(bytes, Keyword.get(opts, :filename, "document.pdf")) do
        {:ok, %{file_id: file_id, document: document}} ->
          {:ok, opts |> Keyword.put(:document, document) |> Keyword.put(:upload_id, file_id)}

        {:error, reason} ->
          Logger.warning(
            "segmented_extraction.upload_fallback bytes=#{byte_size(bytes)} " <>
              "reason=#{inspect(reason)}"
          )

          {:ok, opts}
      end
    else
      {:ok, opts}
    end
  end

  # The packet is a client's invoices sitting in a third party's file store, so it
  # goes as soon as the read is done rather than aging out.
  defp delete_upload(opts) do
    case Keyword.get(opts, :upload_id) do
      nil ->
        :ok

      file_id ->
        case Mistral.delete(file_id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("segmented_extraction.upload_cleanup_failed reason=#{inspect(reason)}")
            :ok
        end
    end
  end

  defp share_document?, do: Application.get_env(:nila, __MODULE__, [])[:share_document] != false

  defp normalize_error({:error, reason, _audit}), do: {:error, reason}
  defp normalize_error(other), do: other

  defp reason({:error, reason, _audit}), do: reason
  defp reason({:error, reason}), do: reason
  defp reason(_ok), do: nil

  defp retryable?({:mistral_ocr_request_failed, %{reason: reason}})
       when reason in [:timeout, :closed, :econnrefused],
       do: true

  defp retryable?({:mistral_ocr_failed, status, _body}) when status in [429, 500, 502, 503, 504],
    do: true

  defp retryable?(_reason), do: false

  # ---- discover ----

  defp discover(kind, transcription, opts, hooks) do
    page_count = Transcription.page_count(transcription)
    report(hooks, segmenting(0, page_count))

    on_page = fn done, total -> report(hooks, segmenting(done, total)) end

    call_opts =
      opts
      |> Keyword.put(:on_page, on_page)
      |> Keyword.put(:shape, :per_page)
      # Which side of the bill the client is on changes both the prompt and the
      # guards — see `Nila.Gst.Extraction.Discovery.guard/3`.
      |> Keyword.put(:kind, kind)

    hooks.per_call.(%{stage: "discovery", pages: page_count}, fn ->
      case Discovery.discover(transcription, call_opts) do
        {:ok, discovery} ->
          {:ok, Map.put(discovery, :audit, discovery_audit(discovery, page_count))}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp segmenting(done, total) do
    %{stage: :segmenting, done: done, total: total, pages_done: done, page_count: total}
  end

  defp discovery_audit(discovery, page_count) do
    %{
      provider: MistralChat.provider(),
      model: MistralChat.model(),
      source_page_count: page_count,
      usage: discovery.usage,
      # `:metadata` is merged into the attempt's `request_metadata` when it
      # finishes. Everything here answers "did it segment, and did anything have
      # to be corrected" — the questions a reviewer opens the row to ask.
      metadata: %{
        "segments" => length(discovery.segments),
        "violations" => Enum.map(discovery.violations, &Discovery.describe/1),
        "non_invoice_pages" =>
          discovery.segments
          |> Enum.filter(&(&1.kind == :non_invoice))
          |> Enum.flat_map(& &1.pages)
      }
    }
  end

  # ---- extract ----

  defp read_segments(kind, transcription, discovery, opts, hooks) do
    segments = discovery.segments
    invoice_count = Enum.count(segments, &(&1.kind == :invoice))
    report(hooks, %{stage: :reading, done: 0, total: invoice_count})

    call_opts =
      Keyword.put(opts, :on_segment, fn done, total ->
        report(hooks, %{stage: :reading, done: done, total: total})
      end)

    hooks.per_call.(%{stage: "extraction", segments: invoice_count}, fn ->
      case Segmented.extract(kind, transcription, segments, call_opts) do
        %{pages: pages} = result ->
          audit = extraction_audit(result, discovery, transcription)

          case pages do
            [] -> {:error, {:no_invoices_extracted, []}, audit}
            _some -> {:ok, Map.put(result, :audit, audit)}
          end

        {:error, reason, segmented_audit} ->
          result = %{pages: [], audit: segmented_audit}
          {:error, reason, extraction_audit(result, discovery, transcription)}
      end
    end)
  end

  # The segmentation travels on the extraction row too: an artifact set is only
  # interpretable next to the cut that produced it, and the two are written by
  # different calls.
  defp extraction_audit(result, discovery, transcription) do
    %{
      provider: result.audit.provider,
      model: result.audit.model,
      usage: result.audit.usage,
      source_page_count: Transcription.page_count(transcription),
      metadata: %{
        "segments" =>
          Enum.map(
            discovery.segments,
            &%{
              "pages" => &1.pages,
              "kind" => to_string(&1.kind),
              "invoice_no" => &1.invoice_no
            }
          ),
        "failures" =>
          Enum.map(result.audit.failures, &%{"pages" => &1.pages, "reason" => inspect(&1.reason)}),
        "repairs" =>
          result.pages
          |> Enum.flat_map(&(&1["repairs"] || []))
          |> Enum.map(&Map.take(&1, ["field", "from", "to", "basis"]))
      }
    }
  end

  # ---- plumbing ----

  defp report(%{on_progress: on_progress}, progress), do: on_progress.({:progress, progress})

  defp call_through(_metadata, call), do: call.()

  defp ignore_progress(_progress), do: :ok

  defp request_id(headers) do
    headers
    |> Map.get("x-request-id", [])
    |> List.first()
  end

  defp error_body(%{body: body}) when is_binary(body), do: String.slice(body, 0, 500)
  defp error_body(%{body: body}), do: inspect(body, limit: 20)
end
