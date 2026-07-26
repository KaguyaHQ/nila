defmodule Nila.Gst.Extraction.Windowed do
  @moduledoc """
  Windowing orchestrator above `Nila.Gst.Extraction.Providers.Mistral`.

  Per-page OCR scales fine; the *annotation* pass — one language model reading a
  whole packet and emitting every invoice as JSON — degrades past ~15 pages,
  silently dropping real invoices and duplicating others while returning HTTP
  200 (evidence and mechanism in `docs/ocr-extraction.md`). So each annotation
  call is kept inside the size where the model behaves: fixed windows of
  `window_size/0` pages overlapping by `overlap/0`, run concurrently, with the
  overlap echoes merged back out.

  Windowing shrinks the failure probability; the **ledger** makes any residual
  failure loud. Every physical page must appear in some window's extracted
  `source_pages` or it comes back in `:unaccounted_pages`, which the flags layer
  turns into a `pages_unaccounted` review flag. A blank separator page fires it
  too — a human glances and dismisses; silence is the failure mode we refuse.

  Small packets keep exactly today's behaviour: an image, or a PDF of at most
  `window_size/0` pages, is one whole-document call with no `pages:` subset.
  """

  alias Nila.Fuzzy
  alias Nila.Gst.Extraction.Providers.Mistral

  require Logger

  # 8 matches Mistral's own historical annotation cap; overlap 2 covers the
  # corpus's longest invoice (2 pages), so no invoice can fall in a crack.
  @window 8
  @overlap 2
  @max_concurrency 4

  @doc "Pages per window."
  def window_size, do: @window

  @doc "Pages each window repeats from its predecessor."
  def overlap, do: @overlap

  @doc """
  Fixed windows over a 1-based page count: `[1..8, 7..14, 13..20, ...]`.

  Stride is `window - overlap`; the last window is clamped to the page count and
  no window ever exceeds `window` pages.
  """
  def plan(page_count, opts \\ [])

  def plan(page_count, _opts) when not is_integer(page_count) or page_count < 1, do: []

  def plan(page_count, opts) do
    window = Keyword.get(opts, :window, @window)
    overlap = Keyword.get(opts, :overlap, @overlap)
    stride = max(window - overlap, 1)

    build_windows(1, page_count, window, stride, [])
  end

  defp build_windows(start, page_count, window, stride, acc) do
    finish = min(start + window - 1, page_count)
    acc = [start..finish | acc]

    if finish >= page_count do
      Enum.reverse(acc)
    else
      build_windows(start + stride, page_count, window, stride, acc)
    end
  end

  @doc """
  Extracts `bytes` window by window and reassembles one packet-level result.

  Returns the extractor contract (`%{pages: , images: , audit: }`) plus
  `:unaccounted_pages`. Supported opts are the provider's, plus:

    * `:per_call` — `(metadata, (-> provider_result)) -> provider_result`, applied
      around every provider call so the caller can persist one audit row per
      window. Defaults to calling straight through.

  Any window that fails after its retry fails the whole extraction, page range
  named. No partial-success dumps: a silently short month is the disease this
  cures, not a feature.
  """
  def extract(kind, bytes, opts \\ []) when kind in [:purchase, :sales] and is_binary(bytes) do
    per_call = Keyword.get(opts, :per_call) || (&call_through/2)
    provider_opts = Keyword.drop(opts, [:per_call, :pages, :page_numbers])

    with {:ok, page_count} <- page_count(bytes, provider_opts) do
      run(kind, bytes, provider_opts, per_call, windows(page_count), page_count)
    end
  end

  defp call_through(_metadata, call), do: call.()

  defp windows(:unknown), do: [:whole_document]
  defp windows(page_count) when page_count <= @window, do: [:whole_document]
  defp windows(page_count), do: plan(page_count)

  defp run(kind, bytes, opts, per_call, [window], page_count) do
    with {:ok, result} <- call_window(kind, bytes, opts, per_call, window) do
      {:ok, assemble([result], page_count)}
    end
  end

  defp run(kind, bytes, opts, per_call, windows, page_count) do
    windows
    |> Task.async_stream(&call_window(kind, bytes, opts, per_call, &1),
      max_concurrency: @max_concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Enum.reduce({:ok, []}, fn
      {:ok, result}, {:ok, acc} -> {:ok, [result | acc]}
      {:error, reason}, {:ok, _acc} -> {:error, reason}
      _result, {:error, _reason} = error -> error
    end)
    |> case do
      {:ok, results} -> {:ok, assemble(Enum.reverse(results), page_count)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # One window: the 0-vs-1-index boundary, and the one cheap retry
  # ---------------------------------------------------------------------------

  # `:pages` is the provider's 0-indexed subset; `:page_numbers` is the same
  # window in 1-based document pages, which is how the artifacts come back
  # numbered. The two must be planned together — hence both set right here.
  defp call_window(kind, bytes, opts, per_call, window) do
    {request_opts, metadata} = window_request(opts, window)

    case attempt(kind, bytes, request_opts, per_call, metadata, 1) do
      {:ok, result} ->
        {:ok, %{window: window, result: result}}

      # A window can legitimately hold no invoice — separator pages, an annexure
      # tail. Its pages simply stay unclaimed and the ledger reports them, where
      # a whole-document call finding nothing is still the failure it always was.
      {:error, :no_invoices_extracted} when window != :whole_document ->
        {:ok, %{window: window, result: %{pages: [], images: %{}, audit: %{}}}}

      {:error, reason} ->
        {:error, {:extraction_window_failed, metadata["pages"], reason}}
    end
  end

  defp window_request(opts, :whole_document) do
    {opts, %{"pages" => "all", "whole_document" => true}}
  end

  defp window_request(opts, first..last//_ = window) do
    page_numbers = Enum.to_list(window)

    request_opts =
      opts
      |> Keyword.put(:pages, Enum.map(page_numbers, &(&1 - 1)))
      |> Keyword.put(:page_numbers, page_numbers)

    {request_opts, %{"pages" => "#{first}-#{last}", "whole_document" => false}}
  end

  # One retry, and only for the failures a retry can fix: Mistral caches OCR on
  # identical document bytes, so a resend after a client timeout lands in
  # seconds (measured — see docs/ocr-extraction.md).
  defp attempt(kind, bytes, request_opts, per_call, metadata, try_number) do
    case per_call.(metadata, fn -> Mistral.extract(kind, bytes, request_opts) end) do
      {:ok, result} ->
        {:ok, result}

      error ->
        reason = error_reason(error)

        if try_number == 1 and retryable?(reason) do
          Logger.warning(
            "windowed_extraction.retry pages=#{metadata["pages"]} reason=#{inspect(reason)}"
          )

          attempt(kind, bytes, request_opts, per_call, metadata, try_number + 1)
        else
          {:error, reason}
        end
    end
  end

  defp error_reason({:error, reason, _audit}), do: reason
  defp error_reason({:error, reason}), do: reason

  defp retryable?({:mistral_ocr_request_failed, %{reason: reason}})
       when reason in [:timeout, :closed, :econnrefused],
       do: true

  defp retryable?({:mistral_ocr_failed, status, _body}) when status in [429, 500, 502, 503, 504],
    do: true

  defp retryable?(_reason), do: false

  # ---------------------------------------------------------------------------
  # Merge: reassemble the packet, then account for every page
  # ---------------------------------------------------------------------------

  defp assemble(window_results, page_count) do
    covered_pages = ledger_page_count(window_results, page_count)

    artifacts =
      window_results
      |> Enum.flat_map(&tag_artifacts(&1, covered_pages))
      |> dedupe()

    %{
      pages: artifacts,
      images: %{},
      audit: merged_audit(window_results, covered_pages),
      unaccounted_pages: unaccounted_pages(artifacts, covered_pages)
    }
  end

  # pdfinfo is the ledger's domain; when it could not read the document (an
  # image, or bytes it refuses) the provider's own page count stands in, so the
  # ledger still covers a whole-document call.
  defp ledger_page_count(_window_results, page_count) when is_integer(page_count), do: page_count

  defp ledger_page_count(window_results, :unknown) do
    window_results
    |> Enum.map(&(&1.result[:audit][:source_page_count] || 0))
    |> Enum.concat([0])
    |> Enum.max()
  end

  defp tag_artifacts(%{window: window, result: result}, page_count) do
    Enum.map(result.pages, fn artifact ->
      source_pages = artifact["source_pages"] || []

      %{
        artifact: artifact,
        source_pages: source_pages,
        richness: richness(artifact),
        interior?: interior?(window, source_pages, page_count)
      }
    end)
  end

  # An invoice touching a window's cut edge was read with less context than the
  # same invoice sitting inside the next window — unless that edge is the
  # document's own edge, where nothing was cut off.
  defp interior?(:whole_document, _source_pages, _page_count), do: true
  defp interior?(_window, [], _page_count), do: true

  defp interior?(first..last//_, source_pages, page_count) do
    starts_at_cut = first > 1 and List.first(source_pages) <= first
    ends_at_cut = last < page_count and List.last(source_pages) >= last

    not (starts_at_cut or ends_at_cut)
  end

  defp richness(artifact) do
    data = artifact["data"] || %{}
    lines = data["line_items"] || []

    Enum.count(data, fn {_key, value} -> value not in [nil, "", []] end) + length(lines)
  end

  # Two adjacent windows both extract any invoice living on their shared pages.
  # Collapsing those echoes is mechanical; the same invoice number appearing on
  # pages that don't touch is a business question ("scanned twice?") and belongs
  # to the `duplicate_invoice` flag at review, so it flows through untouched.
  defp dedupe(tagged) do
    {keyed, keyless} = Enum.split_with(tagged, &(dedupe_key(&1) != nil))

    keyed
    |> Enum.group_by(&dedupe_key/1)
    |> Enum.flat_map(fn {_key, group} -> group |> echo_clusters() |> Enum.map(&collapse/1) end)
    |> Enum.concat(Enum.map(keyless, & &1.artifact))
    |> Enum.sort_by(&{&1["page"] || 0, get_in(&1, ["data", "invoice_number"]) || ""})
  end

  defp dedupe_key(%{artifact: artifact}) do
    data = artifact["data"] || %{}
    invoice_number = Fuzzy.normalize(data["invoice_number"])

    if invoice_number == "" do
      nil
    else
      {Fuzzy.normalize(get_in(data, ["seller", "gstin"])), invoice_number}
    end
  end

  defp echo_clusters(group) do
    group
    |> Enum.sort_by(&{List.first(&1.source_pages) || 0, -&1.richness})
    |> Enum.reduce([], fn tagged, clusters ->
      case clusters do
        [current | rest] ->
          if Enum.any?(current, &touching?(&1.source_pages, tagged.source_pages)),
            do: [[tagged | current] | rest],
            else: [[tagged] | clusters]

        [] ->
          [[tagged]]
      end
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  defp touching?([], _other), do: false
  defp touching?(_pages, []), do: false

  defp touching?(pages, other) do
    Enum.any?(pages, fn page -> Enum.any?(other, &(abs(&1 - page) <= 1)) end)
  end

  defp collapse([%{artifact: artifact}]), do: artifact

  defp collapse(cluster) do
    survivor = Enum.max_by(cluster, &{&1.richness, &1.interior?})
    pages = cluster |> Enum.flat_map(& &1.source_pages) |> Enum.uniq() |> Enum.sort()

    survivor.artifact
    |> Map.put("source_pages", pages)
    |> Map.put("page", List.first(pages) || survivor.artifact["page"])
  end

  defp unaccounted_pages(_artifacts, page_count) when page_count < 1, do: []

  defp unaccounted_pages(artifacts, page_count) do
    covered = artifacts |> Enum.flat_map(&(&1["source_pages"] || [])) |> MapSet.new()

    Enum.reject(1..page_count, &MapSet.member?(covered, &1))
  end

  # Per-window raw responses are persisted per attempt by the caller's
  # `:per_call` wrapper, so the merged audit carries only packet-level totals.
  defp merged_audit(window_results, page_count) do
    usage =
      window_results
      |> Enum.map(&(&1.result[:audit][:usage] || %{}))
      |> Enum.reduce(%{}, fn usage, acc ->
        Map.merge(acc, usage, fn _key, a, b ->
          if is_number(a) and is_number(b), do: a + b, else: b
        end)
      end)

    %{
      provider: Mistral.provider(),
      model: Mistral.model(),
      usage: usage,
      source_page_count: page_count,
      windows: length(window_results)
    }
  end

  # ---------------------------------------------------------------------------
  # Page count — windowing needs it before the first call
  # ---------------------------------------------------------------------------

  defp page_count(bytes, opts) do
    filename = Keyword.get(opts, :filename, "document.pdf")
    content_type = Keyword.get(opts, :content_type) || Mistral.content_type(filename)

    if content_type == "application/pdf", do: pdf_page_count(bytes), else: {:ok, 1}
  end

  defp pdf_page_count(bytes) do
    path =
      Path.join(System.tmp_dir!(), "nila_windowed_#{System.unique_integer([:positive])}.pdf")

    try do
      File.write!(path, bytes)

      case System.cmd(pdfinfo(), [path], stderr_to_stdout: true) do
        {output, 0} -> {:ok, parse_page_count(output)}
        {output, _status} -> {:ok, unreadable(output)}
      end
    rescue
      # pdfinfo missing is an environment fault, not a bad document: failing
      # open would silently put every packet back on the whole-document path.
      error -> {:error, {:pdf_page_count_failed, Exception.message(error)}}
    after
      File.rm(path)
    end
  end

  defp parse_page_count(output) do
    case Regex.run(~r/^Pages:\s+(\d+)/m, output) do
      [_match, count] -> String.to_integer(count)
      nil -> :unknown
    end
  end

  defp pdfinfo, do: Application.get_env(:nila, __MODULE__, [])[:pdfinfo] || "pdfinfo"

  defp unreadable(output) do
    Logger.warning("windowed_extraction.page_count_unreadable #{String.trim(output)}")
    :unknown
  end
end
