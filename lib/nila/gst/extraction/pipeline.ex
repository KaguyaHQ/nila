defmodule Nila.Gst.Extraction.Pipeline do
  @moduledoc """
  Reads a packet by cutting it into bills first and extracting one bill at a time.

  This is the production read. It replaces the windowed one
  (`Nila.Gst.Extraction.Windowed`, kept for its page rendering and for months
  already read through it) because windows were a transport decision doing a
  semantic job: `/v1/ocr` fuses transcription and annotation into a single call,
  only the annotation half has a per-call output budget, and a dense window spent
  one budget across several bills. The same 10-row invoice came back complete
  read alone and 8 rows long read inside an 8-page window — with HTTP 200 either
  way. Shrinking the window shrank the odds; it could not remove them, because
  the unit of extraction was never the unit of correctness.

  Three stages, each with its own failure and its own measurement:

      transcribe   one OCR call, annotation off   → one text per physical page
      discover     one small call per page        → segments, one per bill
      extract      one call per segment           → one invoice, grounded

  Every number a bill prints must be findable in that bill's own transcribed
  text (`Nila.Gst.Extraction.Verify`), which is the check the fused call could
  not offer: there was no text to search, only pixels and an answer.

  ## A bill that will not read

  The windowed path failed the whole month if any window failed, because a
  window held several bills and nobody could say which ones were lost. Here the
  loss is nameable: a segment that fails to extract leaves its pages in
  `:unaccounted_pages`, which the flags layer raises as `pages_unaccounted` for a
  human to read off the scan. Failing 54 good bills over the 55th is not more
  honest, only more expensive — the discipline that matters is that no page ever
  leaves the read in silence, and the ledger still enforces that.

  ## Audit

  One attempt row per stage rather than per call. A 57-page packet is 1 + 57 + 55
  provider calls, and a row apiece would bury the three facts a reviewer actually
  wants — did the scan read, did it segment, did the bills come back. Token usage
  is summed per stage; the transcription's raw response is kept whole because it
  is the text every later stage and every grounding check was run against.
  """

  alias Nila.Gst.Extraction.Discovery
  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Extraction.Providers.MistralChat
  alias Nila.Gst.Extraction.Segmented
  alias Nila.Gst.Extraction.Transcription
  alias Nila.Gst.Extraction.Windowed

  @typedoc """
  One `:on_window` report. `stage` names which of the three is running, because
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
  Packet in, verified invoices out, in `Nila.Gst.Extraction.Windowed.assemble/2`'s
  shape so normalization, the workbench and the eval read either pipeline.

  Options: `:filename` (content type and evidence rendering), `:client_gstin`
  (the client's own number — repairs their own side of a bill and is discounted
  when counting a segment's counterparties), `:per_call` (wraps each stage for
  the audit row) and `:on_window` (progress).
  """
  def extract(kind, bytes, opts \\ []) when kind in [:purchase, :sales] and is_binary(bytes) do
    hooks = %{
      per_call: Keyword.get(opts, :per_call) || (&call_through/2),
      on_window: Keyword.get(opts, :on_window) || (&ignore_progress/1)
    }

    provider_opts = Keyword.drop(opts, [:per_call, :on_window, :on_progress])

    with {:ok, transcription} <- transcribe(bytes, provider_opts, hooks) do
      # Told to us in production, inferred from the packet otherwise, and
      # resolved once so the guards and the repairs cannot disagree about who
      # the client is.
      client = provider_opts[:client_gstin] || Discovery.client_gstin(transcription)
      provider_opts = Keyword.put(provider_opts, :client_gstin, client)

      with {:ok, discovery} <- discover(transcription, provider_opts, hooks),
           {:ok, result} <- read_segments(kind, transcription, discovery, provider_opts, hooks) do
        {:ok, Windowed.attach_evidence(result, bytes, provider_opts)}
      end
    end
  end

  # ---- transcribe ----

  defp transcribe(bytes, opts, hooks) do
    report(hooks, %{stage: :transcribing, done: 0, total: 1})

    hooks.per_call.(%{stage: "transcription"}, fn ->
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
          {:error, {:transcription_failed, response.status, error_body(response)},
           %{http_status: response.status, provider: Mistral.provider(), model: Mistral.model()}}

        {:error, reason, audit} ->
          {:error, reason, audit}

        {:error, reason} ->
          {:error, reason}
      end
    end)
    |> case do
      {:ok, %{transcription: transcription}} -> {:ok, transcription}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transcription_audit(response, page_count) do
    %{
      provider: Mistral.provider(),
      model: Mistral.model(),
      http_status: response.status,
      provider_request_id: request_id(response.headers),
      source_page_count: page_count,
      usage: %{},
      raw_response: response.body
    }
  end

  # ---- discover ----

  defp discover(transcription, opts, hooks) do
    page_count = Transcription.page_count(transcription)
    report(hooks, segmenting(0, page_count))

    on_page = fn done, total -> report(hooks, segmenting(done, total)) end

    call_opts =
      opts
      |> Keyword.put(:on_page, on_page)
      |> Keyword.put(:shape, :per_page)

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
      segments: length(discovery.segments),
      violations: Enum.map(discovery.violations, &Discovery.describe/1)
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
      result = Segmented.extract(kind, transcription, segments, call_opts)
      {:ok, Map.put(result, :audit, extraction_audit(result, discovery, transcription))}
    end)
  end

  # The segmentation travels on the extraction row too: an artifact set is only
  # interpretable next to the cut that produced it, and the two are written by
  # different calls.
  defp extraction_audit(result, discovery, transcription) do
    result.audit
    |> Map.put(:source_page_count, Transcription.page_count(transcription))
    |> Map.put(
      :segmentation,
      Enum.map(discovery.segments, &%{pages: &1.pages, kind: &1.kind, invoice_no: &1.invoice_no})
    )
  end

  # ---- plumbing ----

  defp report(%{on_window: on_window}, progress), do: on_window.({:progress, progress})

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
