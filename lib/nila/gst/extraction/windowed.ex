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

  ## One upload, many windows

  Every window reads the same document, so a multi-window packet is uploaded
  once (`Mistral.upload/2`) and each call references the signed URL. Inlining it
  per window would base64 the whole file into all of them — ~87 MB of request
  bodies to read a 6.9 MB 57-page packet — and base64's 4/3 expansion would cap
  an inlined document at ~37.5 MB against the API's 50 MB limit, rejecting a
  large shoebox for size after a minute of work. The upload is deleted as soon
  as the read finishes; an upload that fails logs and falls back to inlining.
  Set `config :nila, #{inspect(__MODULE__)}, share_document: false` to force the
  inline path.
  """

  alias Nila.Fuzzy
  alias Nila.Gst.Extraction.Providers.Mistral

  require Logger

  # 8 matches Mistral's own historical annotation cap; overlap 2 covers the
  # corpus's longest invoice (2 pages), so no invoice can fall in a crack.
  @window 8
  @overlap 2
  @max_concurrency 16

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
  `:unaccounted_pages`, and `:evidence_error` when the pages could not be
  rendered. `images` are this document's page rasters, keyed by the basename
  each artifact's `"image"` points at. Supported opts are the provider's, plus:

    * `:per_call` — `(metadata, (-> provider_result)) -> provider_result`, applied
      around every provider call so the caller can persist one audit row per
      window. Defaults to calling straight through.

    * `:on_window` — `(event -> any)`, called with `{:progress, t:progress/0}`
      once for the plan and again as each window lands, and with
      `{:retrying, pages}` when a window is resent. Windows run concurrently and
      a packet takes minutes, so this is what lets an intake screen narrate the
      wait in pages rather than showing a dead spinner. A retry is reported for
      the same reason the ledger exists: a stalled window that recovers silently
      looks identical to a screen that has hung.

  Any window that fails after its retry fails the whole extraction, page range
  named. No partial-success dumps: a silently short month is the disease this
  cures, not a feature.
  """
  def extract(kind, bytes, opts \\ []) when kind in [:purchase, :sales] and is_binary(bytes) do
    hooks = %{
      per_call: Keyword.get(opts, :per_call) || (&call_through/2),
      on_window: Keyword.get(opts, :on_window) || (&ignore_progress/1)
    }

    provider_opts = Keyword.drop(opts, [:per_call, :on_window, :pages, :page_numbers])

    with {:ok, page_count} <- page_count(bytes, provider_opts) do
      windows = windows(page_count)
      report(hooks, progress(0, length(windows), MapSet.new(), page_count))

      case shared(kind, bytes, provider_opts, hooks, windows, page_count) do
        {:ok, result} -> {:ok, attach_evidence(result, bytes, provider_opts)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp report(%{on_window: on_window}, progress), do: on_window.({:progress, progress})

  # Many windows read one document, so the document is uploaded once and every
  # window references it. A single window is left alone: one upload plus one
  # signed-URL fetch is two round trips to save an inline body we were going to
  # send exactly once.
  #
  # An upload that fails falls back to inlining rather than failing the read.
  # That path is the one validated against the corpus, so degrading to it is
  # strictly safer than refusing to work — but it degrades *loudly*, because a
  # silent fallback is how a fixed size ceiling comes back unnoticed.
  defp shared(kind, bytes, opts, hooks, windows, page_count) when length(windows) > 1 do
    if share_document?() do
      case Mistral.upload(bytes, Keyword.get(opts, :filename, "document.pdf")) do
        {:ok, %{file_id: file_id, document: document}} ->
          try do
            run(kind, bytes, Keyword.put(opts, :document, document), hooks, windows, page_count)
          after
            delete_quietly(file_id)
          end

        {:error, reason} ->
          Logger.warning(
            "windowed_extraction.upload_fallback windows=#{length(windows)} " <>
              "bytes=#{byte_size(bytes)} reason=#{inspect(reason)}"
          )

          run(kind, bytes, opts, hooks, windows, page_count)
      end
    else
      run(kind, bytes, opts, hooks, windows, page_count)
    end
  end

  defp shared(kind, bytes, opts, hooks, windows, page_count),
    do: run(kind, bytes, opts, hooks, windows, page_count)

  # The document is a client's invoices sitting in a third party's file store,
  # so it goes as soon as the read is done rather than aging out after 24h.
  defp delete_quietly(file_id) do
    case Mistral.delete(file_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("windowed_extraction.upload_cleanup_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp share_document?, do: Application.get_env(:nila, __MODULE__, [])[:share_document] != false

  defp call_through(_metadata, call), do: call.()

  defp ignore_progress(_progress), do: :ok

  @typedoc """
  One `:on_window` report. `pages_done`/`page_count` are the honest unit for a
  human watching (a CA counts pages, not windows); `page_count` is `nil` when
  `pdfinfo` could not read the document, and callers should fall back to
  `done`/`total` there.
  """
  @type progress :: %{
          done: non_neg_integer(),
          total: pos_integer(),
          pages_done: non_neg_integer(),
          page_count: pos_integer() | nil
        }

  defp progress(done, total, covered, page_count) do
    %{
      done: done,
      total: total,
      pages_done: MapSet.size(covered),
      page_count: if(is_integer(page_count), do: page_count)
    }
  end

  # A window's own pages, for the covered-so-far count. This is the *planned*
  # range, not the pages that yielded invoices — the ledger in `assemble/2` owns
  # that stricter question; here we are only narrating how far the read has got.
  defp window_pages(:whole_document, page_count) when is_integer(page_count), do: 1..page_count
  defp window_pages(:whole_document, :unknown), do: 1..1
  defp window_pages(first..last//_, _page_count), do: first..last

  defp windows(:unknown), do: [:whole_document]
  defp windows(page_count) when page_count <= @window, do: [:whole_document]
  defp windows(page_count), do: plan(page_count)

  defp run(kind, bytes, opts, hooks, [window], page_count) do
    with {:ok, result} <- call_window(kind, bytes, opts, hooks, window) do
      covered = window |> window_pages(page_count) |> MapSet.new()
      report(hooks, progress(1, 1, covered, page_count))
      {:ok, assemble([result], page_count)}
    end
  end

  # Reduced over the stream lazily rather than after an `Enum.map`, so each
  # window reports the moment it lands instead of every window reporting at the
  # end. A failed window still consumes the rest (first error wins, as before)
  # rather than halting the stream, which would kill in-flight windows and leave
  # their audit rows open.
  defp run(kind, bytes, opts, hooks, windows, page_count) do
    total = length(windows)

    windows
    |> Task.async_stream(&call_window(kind, bytes, opts, hooks, &1),
      max_concurrency: @max_concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.reduce(%{results: [], covered: MapSet.new(), error: nil}, fn
      {:ok, {:ok, result}}, %{error: nil} = acc ->
        covered = MapSet.union(acc.covered, MapSet.new(window_pages(result.window, page_count)))
        report(hooks, progress(length(acc.results) + 1, total, covered, page_count))
        %{acc | results: [result | acc.results], covered: covered}

      {:ok, {:error, reason}}, %{error: nil} = acc ->
        %{acc | error: reason}

      _outcome, acc ->
        acc
    end)
    |> case do
      %{error: nil, results: results} -> {:ok, assemble(Enum.reverse(results), page_count)}
      %{error: reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # One window: the 0-vs-1-index boundary, and the one cheap retry
  # ---------------------------------------------------------------------------

  # `:pages` is the provider's 0-indexed subset; `:page_numbers` is the same
  # window in 1-based document pages, which is how the artifacts come back
  # numbered. The two must be planned together — hence both set right here.
  defp call_window(kind, bytes, opts, hooks, window) do
    {request_opts, metadata} = window_request(opts, window)

    case attempt(kind, bytes, request_opts, hooks, metadata, 1) do
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
  defp attempt(kind, bytes, request_opts, hooks, metadata, try_number) do
    case hooks.per_call.(metadata, fn -> Mistral.extract(kind, bytes, request_opts) end) do
      {:ok, result} ->
        {:ok, result}

      error ->
        reason = error_reason(error)

        if try_number == 1 and retryable?(reason) do
          Logger.warning(
            "windowed_extraction.retry pages=#{metadata["pages"]} reason=#{inspect(reason)}"
          )

          hooks.on_window.({:retrying, metadata["pages"]})
          attempt(kind, bytes, request_opts, hooks, metadata, try_number + 1)
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
  # Evidence — the page picture a reviewer checks an extracted line against
  # ---------------------------------------------------------------------------

  # Rendering lives here rather than in the provider because the orchestrator is
  # what holds the whole document; a window only ever sees its own slice, and
  # rendering per window would redo the overlap. It runs after the read, not
  # before, so a packet the provider rejects never pays for pictures nobody will
  # look at.
  #
  # A render that fails does NOT fail the extraction. A PDF Mistral can OCR but
  # poppler chokes on still has to produce a register — a month with no pictures
  # beats no month at all. The gap comes back as `:evidence_error` so intake can
  # flag it; a silent gap is the only unacceptable outcome.
  defp attach_evidence(result, bytes, opts) do
    case render_pages(bytes, opts) do
      {:ok, images} ->
        %{result | images: images, pages: Enum.map(result.pages, &put_image(&1, images))}

      {:error, reason} ->
        Logger.warning("windowed_extraction.render_failed reason=#{inspect(reason)}")
        Map.put(result, :evidence_error, reason)
    end
  end

  # An artifact points at the page it was read from. Where the read could not
  # say which page that was (`source_pages` empty — already flagged as
  # attribution-uncertain), it points at none: showing a reviewer the wrong bill
  # is worse than showing them no bill.
  defp put_image(artifact, images) do
    with [page | _rest] <- artifact["source_pages"],
         basename = page_basename(page),
         true <- is_map_key(images, basename) do
      Map.put(artifact, "image", basename)
    else
      _no_page -> Map.put(artifact, "image", nil)
    end
  end

  defp render_pages(bytes, opts) do
    filename = Keyword.get(opts, :filename, "document.pdf")
    content_type = Keyword.get(opts, :content_type) || Mistral.content_type(filename)

    # A packet that arrived as an image is already its own evidence: nothing to
    # rasterize, and nothing broken, so it is not a gap worth flagging.
    if content_type == "application/pdf", do: rasterize(bytes), else: {:ok, %{}}
  end

  # pdftocairo over pdftoppm: same poppler package, same flags, and cairo's
  # antialiasing renders a vector-exported (Tally, Busy) bill more legibly at
  # the same DPI. On a phone photo the two are identical — the page is one
  # embedded raster either way.
  defp rasterize(bytes) do
    dir = Path.join(System.tmp_dir!(), "nila_render_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      pdf_path = Path.join(dir, "source.pdf")
      File.write!(pdf_path, bytes)

      case System.cmd(pdftocairo(), ["-png", "-r", "200", pdf_path, Path.join(dir, "page")],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> {:ok, read_rendered(dir)}
        {output, status} -> {:error, {:page_render_failed, status, String.trim(output)}}
      end
    rescue
      # A missing binary raises rather than exiting non-zero.
      error -> {:error, {:page_render_failed, Exception.message(error)}}
    after
      File.rm_rf(dir)
    end
  end

  # pdftocairo pads its own suffix to the width of the page count — `page-1.png`
  # from a 3-page document, `page-001.png` from a 120-page one. Basenames are
  # re-padded to a fixed two so a page's evidence key reads the same whatever
  # else happened to arrive in the same packet.
  defp read_rendered(dir) do
    dir
    |> Path.join("page-*.png")
    |> Path.wildcard()
    |> Map.new(fn path ->
      [number] = Regex.run(~r/page-(\d+)\.png$/, path, capture: :all_but_first)
      {number |> String.to_integer() |> page_basename(), File.read!(path)}
    end)
  end

  defp page_basename(page), do: "page_#{String.pad_leading(to_string(page), 2, "0")}.png"

  defp pdftocairo, do: Application.get_env(:nila, __MODULE__, [])[:pdftocairo] || "pdftocairo"

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
