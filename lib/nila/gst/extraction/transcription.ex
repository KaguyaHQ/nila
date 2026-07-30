defmodule Nila.Gst.Extraction.Transcription do
  @moduledoc """
  One canonical text per physical page of a document.

  The windowed pipeline never had this: overlapping windows OCR'd the same page
  twice and the two reads disagreed (breeze 2026-06, pages 8, 13, 19 and 20 —
  page 20 came back a delivery challan in one window and a tax invoice in the
  other). Everything downstream of a disagreement is arguing about a page that
  has two texts, so the segmented pipeline reads each page exactly once and
  every later stage — segmentation, extraction, grounding — quotes this
  artifact.

  Tables arrive externalized: the page markdown holds a `[tbl-0.md](tbl-0.md)`
  link and the rows live in `page["tables"]`. A regex, a grounding check and a
  language model reading the "page" all see nothing without them, so they are
  spliced back in at the link's position here, once, rather than in each reader.

  The raw response bytes stay on disk; this struct is derived and may be rebuilt
  from them at any time.
  """

  defstruct pages: %{}, disagreements: []

  @type page :: %{
          number: pos_integer(),
          markdown: String.t(),
          tables: list(),
          confidence: map()
        }

  @type t :: %__MODULE__{pages: %{pos_integer() => page()}, disagreements: [pos_integer()]}

  @doc "Parses one `/v1/ocr` transcription response body."
  def from_response(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body) do
      from_decoded(decoded)
    end
  end

  @doc "Parses an already-decoded transcription response."
  def from_decoded(%{"pages" => pages}) when is_list(pages) do
    {:ok, %__MODULE__{pages: Map.new(pages, fn page -> {number(page), build_page(page)} end)}}
  end

  def from_decoded(_decoded), do: {:error, :missing_pages}

  # `index` is the document-absolute 0-based page number even when the request
  # asked for a subset, so a transport batch needs no re-basing. (The windowed
  # path could not assume this: its annotation numbers pages relative to the
  # window, and reconciling the two numberings is a whole function there.)
  defp number(%{"index" => index}) when is_integer(index), do: index + 1

  defp build_page(page) do
    tables = page["tables"] || []

    %{
      number: number(page),
      markdown: splice_tables(page["markdown"] || "", tables),
      tables: tables,
      confidence: page["confidence_scores"] || %{}
    }
  end

  defp splice_tables(markdown, tables) do
    Enum.reduce(tables, markdown, fn table, acc ->
      id = table["id"]
      content = table["content"] || ""
      link = "[#{id}](#{id})"

      if id && String.contains?(acc, link) do
        String.replace(acc, link, "\n" <> content <> "\n")
      else
        acc <> "\n" <> content <> "\n"
      end
    end)
  end

  @doc """
  Merges transport batches into one transcription.

  Batches are expected to be disjoint. A page read twice with two different
  texts is recorded in `:disagreements` rather than silently resolved — that is
  the failure this module exists to surface, not to hide.
  """
  def merge(transcriptions) do
    Enum.reduce(transcriptions, %__MODULE__{}, fn transcription, acc ->
      Enum.reduce(transcription.pages, acc, fn {number, page}, acc ->
        case acc.pages[number] do
          nil ->
            %{acc | pages: Map.put(acc.pages, number, page)}

          %{markdown: same} when same == page.markdown ->
            acc

          _different ->
            %{acc | disagreements: Enum.uniq([number | acc.disagreements])}
        end
      end)
    end)
  end

  @doc "Page numbers present, ascending."
  def numbers(%__MODULE__{pages: pages}), do: pages |> Map.keys() |> Enum.sort()

  @doc "Page count, which is the ledger's denominator."
  def page_count(%__MODULE__{pages: pages}), do: map_size(pages)

  @doc """
  The text of the given pages, in page order, each prefixed with its page number.

  The marker is there so a model reading a segment can say which page a value
  came from, and so a human reading a prompt log can find the scan.
  """
  def text(%__MODULE__{pages: pages}, numbers) do
    numbers
    |> Enum.sort()
    |> Enum.map_join("\n\n", fn number ->
      case pages[number] do
        nil -> "--- page #{number} (missing) ---"
        page -> "--- page #{number} ---\n" <> page.markdown
      end
    end)
  end

  @doc "Raw markdown of one page, without the page marker."
  def page_text(%__MODULE__{pages: pages}, number) do
    case pages[number] do
      nil -> ""
      page -> page.markdown
    end
  end
end
