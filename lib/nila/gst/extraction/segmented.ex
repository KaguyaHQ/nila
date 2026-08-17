defmodule Nila.Gst.Extraction.Segmented do
  @moduledoc """
  Extracts one invoice per segment, from text, and verifies each one.

  The unit of extraction is the unit of correctness. A page chunk held several
  bills and spent one output budget across all of them, so a dense packet
  truncated — the same 10-row invoice came back complete when read alone and 8
  rows long inside an 8-page chunk. Here every call carries exactly one bill,
  so there is nothing for a budget to be split between.

  Because the input is text, its size is known before the call. A segment whose
  tables exceed `row_limit/0` rows is split across calls and merged in code
  rather than discovered truncated afterwards — the escape hatch the fused
  pixels-in call could not offer, since nobody can count an invoice's rows
  before OCR has read it.

  Page attribution is a fact here, not an inference: the pages handed to the
  call are the pages the invoice came from. `resolve_source_pages/2` and its
  evidence scoring existed in the former fused provider only because a
  multi-invoice annotation had to guess which pages each invoice belonged to.
  """

  alias Nila.Gst.Extraction.Discovery.Features
  alias Nila.Gst.Extraction.LineAmounts
  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.Transcription
  alias Nila.Gst.Extraction.Verify
  alias Nila.Gstin

  @row_limit 150
  @max_concurrency 8

  @doc "Table rows above which a segment is read in parts and merged in code."
  def row_limit, do: @row_limit

  @doc "The single-invoice schema this stage is constrained to."
  def schema(kind), do: Mistral.invoice_schema(kind)

  @doc "The instruction block for one invoice."
  def prompt(kind) do
    """
    You are reading the OCR text of ONE #{kind} invoice from an Indian GST bill \
    packet. The pages below are that invoice and nothing else.

    Return exactly one invoice object.

    - Preserve the economic value of printed numbers. Normalize currency marks \
    and digit grouping as required by the numeric schema, but never replace a \
    printed value with a calculation. If a field is not on these pages, return \
    null. A fabricated number is worse than a missing one and will be caught.
    - item_name is the primary printed product/service text in the item's name \
    or description cell. Keep supplementary narrative in description but do not \
    append it to item_name.
    - Preserve each printed figure in its own role: printed_unit_price is one \
    unit's rate; printed_line_amount is the row's extended amount; \
    printed_line_total is its gross total after separately shown tax; \
    printed_taxable_value is a distinct source field that separately prints the \
    pre-GST value. Never duplicate printed_line_amount into \
    printed_taxable_value merely because the line amount is tax-exclusive.
    - Use headings, table structure and same-row relationships to identify \
    roles, regardless of vendor wording. Populate CGST, SGST or IGST only when \
    the document identifies that tax head.
    - Arithmetic may classify what a printed amount means. For example, a row \
    amount plus separately printed GST equalling its gross total establishes \
    tax-exclusive pricing. Never use arithmetic to populate any extracted \
    numeric field — including quantities, rates, discounts, taxable values or \
    tax amounts — unless that value itself appears on the document. \
    line_amount_tax_inclusion is an inferred semantic field, not a printed number.
    - Respect scope: line and column labels describe their rows; summaries, \
    footer captions and amount-in-words labels describe invoice-level figures. \
    Never assign a summary figure to a line unless it is independently printed \
    there. Clearly visible handwritten or manually entered values are source \
    evidence too.
    - Set line_amount_tax_inclusion from labels, structure or visible arithmetic. \
    Use unknown when evidence is incomplete or conflicting. Do not calculate \
    taxable_value; a later deterministic step does that.
    - Populate singular invoice-level printed_total_* and printed tax-head \
    fields only when that invoice-level aggregate is itself printed. Never \
    select, combine or sum tax-rate or slab-summary rows to create an aggregate, \
    and never redistribute summary figures across item rows.
    - Include every real item row. Never turn a subtotal, total, HSN summary or \
    amount-in-words row into a line item.
    - The invoice may be internally inconsistent — its own printed total may \
    disagree with its lines. Copy what is printed anyway; a later check names \
    the discrepancy.
    #{kind_rules(kind)}\
    """
  end

  # The former sales prompt carried two clauses this stage must not lose. A
  # cancelled invoice still occupies its number, and a return that omits it
  # reports a gap in the series it cannot explain. And an intra-state bill that
  # prints CGST and SGST as stacked sub-rows under each item will, if those are
  # read as two items, be filed at half its rate — the documented invoice-27
  # failure in `Nila.Gst.Sales.Gstr1`.
  defp kind_rules(:sales) do
    """
    - Classify the document itself as invoice, credit_note or debit_note. A title \
    reading CREDIT NOTE or DEBIT NOTE controls; footer terms that merely mention \
    notes do not.
    - For a credit or debit note, invoice_number is the note number only. Exclude \
    labels such as "Credit Note:" from the value.
    - Include cancelled invoices. A cancelled number is still a number the \
    series has to account for, and classify its document_status as cancelled so \
    it cannot be filed as an active taxable invoice.
    - A printed recipient GSTIN means recipient_registration is registered. Use \
    unregistered only when the document positively identifies an unregistered or \
    consumer recipient. A missing or unreadable GSTIN alone is unknown, never a \
    silent B2C inference.
    - Copy the printed place of supply exactly. Do not substitute the billing or \
    shipping state when the document does not state its place of supply.
    - Preserve nil-rated, exempt, non-GST, export and SEZ treatment in supply_type. \
    Never coerce one of them to an ordinary taxable sale.
    - CGST and SGST printed as stacked sub-rows under one item are that item's \
    tax, not two items. Never split them, and never split a total row.
    """
  end

  defp kind_rules(:purchase) do
    """
    - Classify the supplier document itself as invoice, credit_note or debit_note. \
    A title reading CREDIT NOTE or DEBIT NOTE controls; footer terms that merely \
    mention notes do not.
    - For a credit or debit note, invoice_number is the note number only. Exclude \
    labels such as "Credit Note:" or "Debit Note:" from the value. Keep every \
    printed amount positive; document_type determines its accounting effect.
    """
  end

  @doc """
  Extracts and verifies every invoice segment.

  Returns the extraction-result shape consumed by scoring, normalization and
  the workbench.

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
        fn segment -> {segment, contained(kind, transcription, segment, opts)} end,
        max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
        # Ordered delivery would drain the buffer in submission order, so one
        # segment sitting in rate-limit backoff holds back the count for every
        # segment behind it — a bar frozen at zero while thirteen bills are
        # already read, and thirteen artifacts held live waiting on the first.
        # Nothing downstream reads this order: artifacts are sorted by page and
        # failures by their first page.
        ordered: false,
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

    audit = %{
      provider: OpenAICompatibleChat.provider(),
      model: OpenAICompatibleChat.model(),
      segments: length(segments),
      invoice_segments: total,
      usage: artifacts |> Enum.map(& &1["usage"]) |> sum_usage(),
      failures: results |> Enum.flat_map(&failure/1) |> Enum.sort_by(&List.first(&1.pages))
    }

    if audit.failures == [] do
      %{
        pages: artifacts,
        images: %{},
        audit: audit,
        unaccounted_pages: unaccounted_pages(transcription, segments, artifacts)
      }
    else
      {:error, {:invoice_segments_failed, audit.failures}, audit}
    end
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

  # A raise inside an `async_stream` child reaches the caller as an exit, and no
  # `try/rescue` up the stack catches an exit — the audit row would stay open and
  # the dump would sit in `extracting` forever. Contained here, a malformed
  # response becomes a regular stage failure and no partial result can publish.
  defp contained(kind, transcription, segment, opts) do
    try do
      extract_segment(kind, transcription, segment, opts)
    rescue
      error -> {:error, {:segment_crashed, Exception.message(error)}}
    catch
      thrown, value -> {:error, {:segment_crashed, inspect({thrown, value})}}
    end
  end

  @doc "One segment: call, map, verify."
  def extract_segment(kind, transcription, segment, opts \\ []) do
    case request_segment(kind, transcription, segment, opts) do
      {:ok, responses} -> map_segment(kind, transcription, segment, responses, opts)
      {:error, reason, _completed_responses} -> {:error, reason}
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
        {:error, reason} -> {:halt, {:error, reason, acc}}
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

    OpenAICompatibleChat.request_raw(messages, "nila_#{kind}_invoice", schema(kind), opts)
  end

  @doc """
  Maps cached or live chunk responses into one verified artifact.

  `:client_gstin` is the client's own GSTIN, used to repair a scan-damaged
  reading of their own side of the bill — see `repair_gstins/3`.
  """
  def map_segment(kind, transcription, segment, responses, opts \\ []) do
    decoded =
      Enum.reduce_while(responses, {:ok, [], []}, fn %{response: response}, {:ok, acc, usage} ->
        case OpenAICompatibleChat.decode(response, schema(kind)) do
          {:ok, invoice, call_usage} -> {:cont, {:ok, acc ++ [invoice], usage ++ [call_usage]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, invoices, usage} <- decoded do
      {data, repairs} =
        invoices |> merge_chunks() |> markers(kind) |> repair_gstins(kind, opts[:client_gstin])

      text = Transcription.text(transcription, segment.pages)
      candidate_verification = Verify.invoice(data, text, repairs)

      {data, discarded} = Verify.discard_unobserved_values(data, candidate_verification.checks)

      {data, redundant} = discard_redundant_taxable_candidates(data)
      repairs = repairs ++ discarded ++ redundant
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
         # What the page says it is, for the shapes the return has no table
         # for — see `Nila.Gst.Extraction.Verify.document_markers/1`.
         "document" =>
           text
           |> Verify.document_markers()
           |> Map.put("extracted_type", data["document_type"]),
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

  defp discard_redundant_taxable_candidates(data) do
    {lines, repairs} =
      data
      |> Map.get("line_items", [])
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {line, index}, repairs ->
        case LineAmounts.discard_redundant_printed_taxable(line) do
          {line, nil} ->
            {line, repairs}

          {line, repair} ->
            repair = Map.update!(repair, "field", &"line_items[#{index}].#{&1}")
            {line, repairs ++ [repair]}
        end
      end)

    {Map.put(data, "line_items", lines), repairs}
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

  @doc "Applies the provider-independent repairs shared by text and vision extraction."
  def prepare_vision_data(data, kind, client_gstin) do
    {data, repairs} = data |> markers(kind) |> repair_gstins(kind, client_gstin)
    {data, redundant} = discard_redundant_taxable_candidates(data)
    {data, repairs ++ redundant}
  end

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

  # A page in no invoice artifact is reported by the ledger, except when the
  # decider confirmed it as a non-invoice and therefore accounted for it.
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
