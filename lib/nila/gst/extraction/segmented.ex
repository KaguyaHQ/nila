defmodule Nila.Gst.Extraction.Segmented do
  @moduledoc """
  Extracts one invoice per segment, from text, and verifies each one.

  The unit of extraction is the unit of correctness. A window held several bills
  and spent one output budget across all of them, so a dense packet truncated —
  the same 10-row invoice came back complete when read alone and 8 rows long
  when read inside an 8-page window. Here every call carries exactly one bill,
  so there is nothing for a budget to be split between.

  Because the input is text, its size is known before the call. A segment whose
  tables exceed `row_limit/0` rows is split across calls and merged in code
  rather than discovered truncated afterwards — the escape hatch the fused
  pixels-in call could not offer, since nobody can count an invoice's rows
  before OCR has read it.

  Page attribution is a fact here, not an inference: the pages handed to the
  call are the pages the invoice came from. `resolve_source_pages/2` and its
  evidence scoring exist in the windowed provider only because a whole-window
  annotation had to guess which of eight pages each invoice belonged to.
  """

  alias Nila.Gst.Extraction.Discovery.Features
  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Extraction.Providers.MistralChat
  alias Nila.Gst.Extraction.Transcription
  alias Nila.Gst.Extraction.Verify
  alias Nila.Gstin

  @row_limit 150
  @max_concurrency 8

  @doc "Table rows above which a segment is read in parts and merged in code."
  def row_limit, do: @row_limit

  @doc "The single-invoice schema this stage is constrained to."
  def schema(kind), do: Mistral.invoice_schema(kind, source_pages: false)

  @doc "The instruction block for one invoice."
  def prompt(kind) do
    """
    You are reading the OCR text of ONE #{kind} invoice from an Indian GST bill \
    packet. The pages below are that invoice and nothing else.

    Return exactly one invoice object.

    - Copy printed values exactly. Never compute a value that is printed, and \
    never print a value you cannot see: if a field is not on these pages, return \
    null. A fabricated number is worse than a missing one and will be caught.
    - taxable_value on a line means the post-discount value before GST, never \
    the list value or a pre-discount subtotal.
    - When a GST slab, tax summary or CGST/SGST outward block is printed, copy \
    its taxable turnover and tax amounts into the printed_* fields exactly. Do \
    not recalculate them and do not redistribute them across item rows.
    - Handwritten tax and total boxes are printed values too.
    - Include every real item row. Never turn a subtotal, total, HSN summary or \
    amount-in-words row into a line item.
    - The invoice may be internally inconsistent — its own printed total may \
    disagree with its lines. Copy what is printed anyway; a later check names \
    the discrepancy.
    """
  end

  @doc """
  Extracts and verifies every invoice segment.

  Returns the same shape `Nila.Gst.Extraction.Windowed.assemble/2` returns, so
  scoring, normalization and the workbench read either pipeline unchanged.

  `:on_segment` is called with `{done, total}` as each segment lands, so a
  caller can narrate a long read.
  """
  def extract(kind, %Transcription{} = transcription, segments, opts \\ []) do
    invoice_segments = Enum.filter(segments, &(&1.kind == :invoice))
    total = length(invoice_segments)
    report = Keyword.get(opts, :on_segment) || fn _done, _total -> :ok end

    results =
      invoice_segments
      |> Task.async_stream(
        fn segment -> {segment, extract_segment(kind, transcription, segment, opts)} end,
        max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
        timeout: :infinity
      )
      # Mapped over the stream rather than after it, so each segment narrates as
      # it lands instead of every segment narrating at the end.
      |> Stream.with_index(1)
      |> Enum.map(fn {{:ok, result}, done} ->
        report.(done, total)
        result
      end)

    artifacts =
      results
      |> Enum.flat_map(fn
        {_segment, {:ok, artifact}} -> [artifact]
        {_segment, {:error, _reason}} -> []
      end)
      |> Enum.sort_by(& &1["page"])

    %{
      pages: artifacts,
      images: %{},
      audit: %{
        provider: MistralChat.provider(),
        model: MistralChat.model(),
        segments: length(segments),
        invoice_segments: total,
        usage: artifacts |> Enum.map(& &1["usage"]) |> sum_usage(),
        failures: Enum.flat_map(results, &failure/1)
      },
      unaccounted_pages: unaccounted_pages(transcription, segments, artifacts)
    }
  end

  defp failure({segment, {:error, reason}}), do: [%{pages: segment.pages, reason: reason}]
  defp failure(_ok), do: []

  @doc "Adds up token counts across calls, keeping whatever keys the provider sent."
  def sum_usage(usages) do
    usages
    |> Enum.reject(&(!is_map(&1)))
    |> Enum.reduce(%{}, fn usage, acc ->
      Map.merge(acc, usage, fn
        _key, left, right when is_number(left) and is_number(right) -> left + right
        _key, left, _right -> left
      end)
    end)
  end

  @doc "One segment: call, map, verify."
  def extract_segment(kind, transcription, segment, opts \\ []) do
    with {:ok, responses} <- request_segment(kind, transcription, segment, opts) do
      map_segment(kind, transcription, segment, responses, opts)
    end
  end

  @doc """
  The provider calls for one segment: one per chunk, and almost always one chunk.
  """
  def request_segment(kind, transcription, segment, opts \\ []) do
    segment.pages
    |> chunks(transcription)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case request_chunk(kind, transcription, chunk, length(acc), opts) do
        {:ok, response} -> {:cont, {:ok, acc ++ [%{pages: chunk, response: response}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp request_chunk(kind, transcription, pages, index, opts) do
    text = Transcription.text(transcription, pages)

    content =
      if index == 0 do
        prompt(kind) <> "\n\n" <> text
      else
        prompt(kind) <>
          "\n\nThese pages are a CONTINUATION of the same invoice. Return the item " <>
          "rows printed on these pages, and header or total fields only when they " <>
          "are printed here.\n\n" <> text
      end

    messages = [
      %{role: "system", content: "You read invoices into JSON. You answer only in JSON."},
      %{role: "user", content: content}
    ]

    MistralChat.request_raw(messages, "nila_#{kind}_invoice", schema(kind), opts)
  end

  @doc """
  Maps cached or live chunk responses into one verified artifact.

  `:client_gstin` is the client's own GSTIN, used to repair a scan-damaged
  reading of their own side of the bill — see `repair_gstins/3`.
  """
  def map_segment(kind, transcription, segment, responses, opts \\ []) do
    decoded =
      Enum.reduce_while(responses, {:ok, [], []}, fn %{response: response}, {:ok, acc, usage} ->
        case MistralChat.decode(response) do
          {:ok, invoice, call_usage} -> {:cont, {:ok, acc ++ [invoice], usage ++ [call_usage]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, invoices, usage} <- decoded do
      {data, repairs} =
        invoices |> merge_chunks() |> markers(kind) |> repair_gstins(kind, opts[:client_gstin])

      text = Transcription.text(transcription, segment.pages)
      verification = Verify.invoice(data, text, repairs)

      {:ok,
       %{
         "kind" => artifact_kind(kind),
         "version" => 1,
         "page" => List.first(segment.pages),
         "source_pages" => segment.pages,
         # Attribution is known by construction: these are the pages the call read.
         "source_attribution" => %{
           "status" => "verified",
           "candidate_pages" => segment.pages,
           "source" => "segment"
         },
         "image" => nil,
         "data" => data,
         "confidence" => confidence(transcription, segment, verification),
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
         # Per-invoice, because that is the unit the call was made in and the
         # unit a cost per bill is quoted in.
         "usage" => sum_usage(usage),
         "segment" => %{
           "pages" => segment.pages,
           "invoice_no_candidate" => segment.invoice_no,
           "issues" => Enum.map(segment.issues, &inspect(&1, charlists: :as_lists))
         }
       }}
    end
  end

  # Header and total fields come from whichever chunk actually printed them;
  # line items are the concatenation, in page order.
  defp merge_chunks([invoice]), do: invoice

  defp merge_chunks(invoices) do
    Enum.reduce(invoices, fn invoice, acc ->
      merged =
        Map.merge(acc, invoice, fn
          "line_items", left, right -> (left || []) ++ (right || [])
          _key, left, nil -> left
          _key, nil, right -> right
          _key, left, _right -> left
        end)

      merged
    end)
  end

  defp markers(data, :purchase) do
    data
    |> Map.put("is_invoice", true)
    |> Map.put("continuation_of_previous", false)
  end

  defp markers(data, :sales), do: data

  @doc """
  Repairs GSTINs the scanner damaged, on evidence, and records every repair.

  Two oracles, both stronger than the model's own reading:

    * the **format itself** — `Nila.Gstin.repair/1` corrects a damaged GSTIN
      when the fixed grammar plus the check digit leave exactly one legal
      reading, and refuses when they leave two;
    * the **known client** — every page of a client's own packet prints their
      own GSTIN, so a field that fails its check digit next to a near-identical
      known value is a scan artefact, not a different company. The threshold is
      deliberately high, and it applies to the client's own side only (buyer on
      a purchase packet, seller on a sales one): that identity is a fact we hold
      independently, the counterparty's is not.

  Left alone otherwise. An invalid GSTIN nobody can resolve stays invalid and
  the verifier flags it, which is the correct outcome — the alternative is a
  purchase attributed to a supplier who does not exist.
  """
  def repair_gstins(data, kind, client_gstin) do
    {seller, seller_repair} =
      repair_party(data["seller"], "seller.gstin", known(kind, :seller, client_gstin))

    {buyer, buyer_repair} =
      repair_party(data["buyer"], "buyer.gstin", known(kind, :buyer, client_gstin))

    data =
      data
      |> maybe_put("seller", seller)
      |> maybe_put("buyer", buyer)

    {data, Enum.reject([seller_repair, buyer_repair], &is_nil/1)}
  end

  # The client is the buyer on their own purchase packet and the seller on their
  # own sales packet. Only the side we hold independently may be snapped to:
  # snapping the other side would rewrite a counterparty's identity from a
  # value that has nothing to do with them. On a sales packet that is not a
  # hypothetical — the customer's GSTIN changes every bill while the client's
  # does not, so a buyer-snapping rule would smear the client's own number
  # across their customers.
  defp known(:purchase, :buyer, gstin), do: gstin
  defp known(:sales, :seller, gstin), do: gstin
  defp known(_kind, _party, _gstin), do: nil

  defp maybe_put(data, _key, nil), do: data
  defp maybe_put(data, key, value), do: Map.put(data, key, value)

  defp repair_party(party, field, known) when is_map(party) do
    case repair_gstin(party["gstin"], known) do
      nil ->
        {party, nil}

      {repaired, basis} ->
        {Map.put(party, "gstin", repaired), repair(field, party["gstin"], repaired, basis)}
    end
  end

  defp repair_party(party, _field, _known), do: {party, nil}

  defp repair_gstin(value, known) when is_binary(value) and value != "" do
    case Gstin.repair(value) do
      {:ok, _valid} -> nil
      {:repaired, repaired} -> {repaired, "grammar_and_check_digit"}
      :error -> snap_to_known(value, known)
    end
  end

  defp repair_gstin(_value, _known), do: nil

  @similarity 0.8

  defp snap_to_known(value, known) when is_binary(known) do
    if String.jaro_distance(String.upcase(value), known) >= @similarity do
      {known, "known_client"}
    end
  end

  defp snap_to_known(_value, _known), do: nil

  defp repair(field, from, to, basis) do
    %{"field" => field, "from" => from, "to" => to, "basis" => basis}
  end

  defp confidence(transcription, segment, verification) do
    scores =
      segment.pages
      |> Enum.map(&get_in(transcription.pages, [&1, :confidence]))
      |> Enum.reject(&is_nil/1)

    %{"source_attribution" => 1.0, "verification" => to_string(verification.status)}
    |> put_min(scores, "minimum_page_confidence_score", "ocr_minimum")
    |> put_min(scores, "average_page_confidence_score", "ocr_average")
  end

  defp put_min(confidence, scores, key, name) do
    case scores |> Enum.map(& &1[key]) |> Enum.reject(&is_nil/1) do
      [] -> confidence
      values -> Map.put(confidence, name, Enum.min(values))
    end
  end

  defp encode_flag({name, detail}), do: %{"flag" => to_string(name), "detail" => inspect(detail)}

  # A page in no invoice artifact is reported, exactly as the windowed ledger
  # reported it — except a page the decider called non-invoice is accounted for,
  # not missing.
  defp unaccounted_pages(transcription, segments, artifacts) do
    claimed =
      artifacts
      |> Enum.flat_map(& &1["source_pages"])
      |> Enum.concat(
        segments
        |> Enum.filter(&(&1.kind == :non_invoice))
        |> Enum.flat_map(& &1.pages)
      )
      |> MapSet.new()

    transcription
    |> Transcription.numbers()
    |> Enum.reject(&MapSet.member?(claimed, &1))
  end

  # The row budget is spent per call, so pages are grouped until the next one
  # would overrun it. A single page above the limit still gets its own call —
  # nothing smaller than a page can be split without splitting a table.
  defp chunks(pages, transcription) do
    rows = Map.new(pages, &{&1, page_rows(transcription, &1)})

    if pages |> Enum.map(&rows[&1]) |> Enum.sum() <= @row_limit do
      [pages]
    else
      pages
      |> Enum.chunk_while(
        {[], 0},
        fn page, {chunk, count} ->
          if chunk != [] and count + rows[page] > @row_limit do
            {:cont, Enum.reverse(chunk), {[page], rows[page]}}
          else
            {:cont, {[page | chunk], count + rows[page]}}
          end
        end,
        fn
          {[], _count} -> {:cont, []}
          {chunk, _count} -> {:cont, Enum.reverse(chunk), {[], 0}}
        end
      )
      |> Enum.reject(&(&1 == []))
    end
  end

  defp page_rows(transcription, page) do
    transcription |> Transcription.page_text(page) |> Features.scan() |> Map.fetch!(:table_rows)
  end

  defp artifact_kind(:purchase), do: "purchase_invoice_extraction"
  defp artifact_kind(:sales), do: "gstr1_sales_invoice_extraction"
end
