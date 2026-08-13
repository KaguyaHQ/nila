defmodule Nila.Gst.Extraction.Discovery do
  @moduledoc """
  Cuts a transcribed packet into segments — one per bill — before anything is
  extracted.

  This is the stage the former chunked reader never had. There, the unit of
  extraction was a fixed 8-page chunk and the unit of correctness was one
  invoice, so a single call had to hold several bills at once and spend one
  output budget across all of them; a dense multi-invoice chunk truncated
  systematically, dropping real line items while returning HTTP 200. Deciding
  boundaries *first* makes the two units the same, and a per-invoice call can
  no more run out of budget than the invoice can run out of rows.

  The decider is a cheap text model, not the heuristics in
  `#{inspect(__MODULE__)}.Features` — those fail confidently (see that module) —
  and not the expensive vision model, which would put the whole packet's pixels
  back in one call. Text in, boundaries out.

  A model deciding is only safe because deterministic guards check it afterwards:

    * **conservation** — every physical page lands in exactly one segment. A page
      the model forgets becomes an `:unreadable` segment and a violation, never
      silence. This is the same ledger discipline the former reader used, kept
      because it is the only reason a dropped page is ever noticed.
    * **contiguity** — a segment's pages are a contiguous run. Scanned packets do
      not interleave, so a non-contiguous segment is a model error by
      construction.
    * **grounding** — a claimed invoice number must appear in that segment's own
      text. The model may not name a number that is not on the page.
    * **one seller** — an invoice has one supplier, so a segment whose pages
      carry two different valid seller GSTINs is a merge of two bills. (The
      client's own GSTIN is on every page of the packet and is discounted.) This
      caught a real merge the model made on breeze 2026-06: a page titled
      "Tax Invoice(Page 2)" was attached to the *next* bill rather than left
      alone, and the two pages named different suppliers.

  Where the line sits, precisely, because it is the kind of line that creeps:
  **a guard repairs only on proof, and flags on everything less.** Two different
  supplier GSTINs on two pages of one segment, or two different document numbers
  each printed on its own page, are not suspicions about a boundary — they are
  the boundary, stated by the documents. Code acts on those. Code never merges
  on suspicion, never invents a boundary the text does not prove, and never
  repairs quietly: every intervention is recorded on the segment and raised as a
  violation, so the eval can score the decider raw and repaired separately and
  say whether the guards are carrying a model that should be replaced.
  """

  alias Nila.Gst.Extraction.Discovery.Features
  alias Nila.Gst.Extraction.Discovery.PageLabels
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.Segmented
  alias Nila.Gst.Extraction.Transcription

  # A pathological page (a 400-row annexure) should not dominate the prompt; the
  # decider needs a page's shape and its identifiers, not every row of it.
  @page_char_limit 4_000

  @doc "The JSON schema the decider is constrained to."
  def schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["segments"],
      properties: %{
        segments: %{
          type: "array",
          description:
            "Every document in the packet, in page order, covering every page exactly once.",
          items: %{
            type: "object",
            additionalProperties: false,
            required: ["pages", "kind", "invoice_no", "reason"],
            properties: %{
              pages: %{
                type: "array",
                description:
                  "The 1-based page numbers of this document, ascending and contiguous.",
                items: %{type: "integer", minimum: 1},
                minItems: 1
              },
              kind: %{
                type: "string",
                enum: ["invoice", "non_invoice", "unreadable"],
                description:
                  "invoice: a tax invoice, bill of supply, or debit/credit note. non_invoice: delivery challan, e-way bill, transport trip sheet, purchase order, payment slip, blank or separator page. unreadable: text too garbled to tell."
              },
              invoice_no: %{
                anyOf: [%{type: "string"}, %{type: "null"}],
                description:
                  "The document number exactly as printed on the page, or null when none is printed or legible. Never invent or reformat one."
              },
              reason: %{
                anyOf: [%{type: "string"}, %{type: "null"}],
                description: "Short note on why this boundary was chosen. Null when obvious."
              }
            }
          }
        }
      }
    }
  end

  @doc "The instruction block, hashed into the cache key by callers."
  def prompt do
    """
    You are segmenting a scanned packet of Indian GST bills. The pages below are \
    in scan order, each with deterministic signals read off it and then its OCR \
    text.

    Split the packet into documents. Rules:

    - Every page number appears in exactly one segment. Do not drop a page, do \
    not place it twice.
    - A segment's pages are contiguous. Packets are scanned in order.
    - A multi-page bill is ONE segment holding all its pages, never one segment \
    per page.
    - A repeated letterhead does not start a new bill. A continuation page \
    repeats the seller's header but carries on the same item table and prints no \
    new document number. Conversely, two bills from the same supplier look \
    nearly identical apart from the number and date — a fresh number or date \
    with an item table starting again at row 1 is a new bill.
    - A bill usually closes where totals, tax summary or amount-in-words appear; \
    absence of that is a hint that the next page continues it.
    - invoice_no must be copied exactly from the page. If you cannot read one, \
    return null. A wrong number is worse than no number.
    - A bill's own pages name one supplier. Two different supplier GSTINs mean \
    two bills, however alike the pages look.
    - Delivery challans, e-way bills, transport trip sheets, purchase orders, \
    payment slips, blank and separator pages are their own segments with \
    kind "non_invoice". But judge by what the document charges, not by its \
    title: a "TAX INVOICE CUM DELIVERY CHALLAN" is an invoice, and a transport \
    operator's consignment note that charges GST is an invoice. A trip receipt \
    with no GST on it is not.
    """
  end

  @doc """
  Asks the decider for boundaries, returning the raw response.

  Split from `map_response/2` for the same reason the OCR call is: the eval
  harness caches bytes at the network boundary and re-runs the guards at score
  time, so tightening a guard never costs an API call and never hides behind a
  cache hit.
  """
  def request_raw(%Transcription{} = transcription, opts \\ []) do
    messages = [
      %{
        role: "system",
        content: "You segment scanned document packets. You answer only in JSON."
      },
      %{role: "user", content: prompt() <> "\n\n" <> pages_block(transcription)}
    ]

    OpenAICompatibleChat.request_raw(messages, "nila_packet_segments", schema(), opts)
  end

  @doc "Decodes a whole-dump decider response and runs the guards over it."
  def map_response(%Transcription{} = transcription, response, opts \\ []) do
    with {:ok, content, usage} <- OpenAICompatibleChat.decode(response, schema()) do
      segments = content["segments"] |> List.wrap() |> Enum.map(&normalize/1)
      {segments, violations} = guard(transcription, segments, opts)
      {:ok, %{segments: segments, violations: violations, usage: usage}}
    end
  end

  @doc """
  Transcription in, guarded segments out.

  `shape: :per_page` labels each page against its neighbours and stitches the
  labels in code (`#{inspect(__MODULE__)}.PageLabels`); `shape: :whole_dump`
  asks one call for the finished segmentation. Both hand their result to the
  same guards, which is what makes the two comparable on one metric — see
  `Nila.Eval.Segmentation`.
  """
  def discover(%Transcription{} = transcription, opts \\ []) do
    case Keyword.get(opts, :shape, :per_page) do
      :whole_dump ->
        with {:ok, response} <- request_raw(transcription, opts) do
          map_response(transcription, response, opts)
        end

      :per_page ->
        with {:ok, responses} <- PageLabels.request_all(transcription, opts),
             {:ok, labels} <- PageLabels.map_responses(responses) do
          {segments, violations} = guard(transcription, PageLabels.stitch(labels), opts)

          usage = labels |> Enum.map(&Map.get(&1, :usage)) |> Segmented.sum_usage()
          {:ok, %{segments: segments, violations: violations, usage: usage}}
        end
    end
  end

  defp pages_block(transcription) do
    transcription
    |> Transcription.numbers()
    |> Enum.map_join("\n\n", fn number ->
      text = Transcription.page_text(transcription, number)
      features = Features.scan(text)

      """
      === page #{number} ===
      signals: #{Features.summary(features)}
      #{clip(text)}
      """
    end)
  end

  defp clip(text) do
    if String.length(text) > @page_char_limit do
      String.slice(text, 0, @page_char_limit) <> "\n… [page text truncated]"
    else
      text
    end
  end

  # ---- guards ----

  @doc """
  Runs every guard over already-normalized segments, whatever produced them.

  Both decider shapes end here, so a change to a guard changes both at once and
  neither can quietly acquire a rule the other lacks.

  Options: `:client_gstin`, the client's own number — told to us in production
  and inferred from the packet when nobody has (see `client_gstin/1`) — and
  `:kind`, which decides whether a counterparty GSTIN proves anything. On a
  purchase pile the counterparty is the supplier and two of them prove two
  bills; on a sales pile the counterparty is the customer, one bill can print
  two of them (bill-to and ship-to), and the party that *is* constant is the
  client. So the party guards apply to purchase only, and sales is cut on
  printed document numbers alone.
  """
  def guard(transcription, segments, opts \\ [])

  def guard(transcription, segments, client_gstin)
      when is_binary(client_gstin) or is_nil(client_gstin),
      do: guard(transcription, segments, client_gstin: client_gstin)

  def guard(transcription, segments, opts) when is_list(opts) do
    client_gstin = Keyword.get(opts, :client_gstin)
    kind = Keyword.get(opts, :kind, :purchase)
    known = Transcription.numbers(transcription) |> MapSet.new()

    {claimed, seen} =
      segments
      |> Enum.reject(&(&1.pages == []))
      |> Enum.sort_by(&List.first(&1.pages))
      |> Enum.map_reduce(MapSet.new(), &claim_pages(&1, &2, known))

    missing = known |> MapSet.difference(seen) |> Enum.sort()

    client = client_gstin || client_gstin(transcription)

    segments =
      (claimed ++ Enum.map(missing, &unassigned_segment/1))
      # A segment whose every page was already claimed has nothing left to
      # extract, but its double-claim is carried out as a violation below rather
      # than dropped with it.
      |> Enum.reject(&(&1.pages == []))
      |> Enum.flat_map(&split_on_evidence(&1, transcription, client, kind))
      |> Enum.map(&ground(&1, transcription))
      |> Enum.map(&one_seller(&1, transcription, client, kind))
      |> Enum.map(&confirm_kind(&1, transcription, client, kind))
      |> Enum.sort_by(&List.first(&1.pages))

    {segments, violations(segments, missing, double_claimed(claimed))}
  end

  defp double_claimed(segments) do
    segments
    |> Enum.flat_map(fn segment ->
      Enum.flat_map(segment.issues, fn
        {:pages_already_claimed, pages} -> pages
        _other -> []
      end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize(segment) do
    %{
      pages:
        segment
        |> Map.get("pages", [])
        |> Enum.filter(&is_integer/1)
        |> Enum.uniq()
        |> Enum.sort(),
      kind: kind(segment["kind"]),
      invoice_no: blank_to_nil(segment["invoice_no"]),
      reason: blank_to_nil(segment["reason"]),
      issues: []
    }
  end

  defp kind("invoice"), do: :invoice
  defp kind("non_invoice"), do: :non_invoice
  defp kind(_other), do: :unreadable

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # A page claimed twice belongs to whichever segment claims it first; the second
  # claim is recorded on that segment rather than honoured, so the double-claim
  # is visible instead of arbitrated in silence.
  defp claim_pages(segment, seen, known) do
    {pages, dropped} =
      Enum.split_with(
        segment.pages,
        &(MapSet.member?(known, &1) and not MapSet.member?(seen, &1))
      )

    segment =
      segment
      |> Map.put(:pages, pages)
      |> add_issue(dropped != [], {:pages_already_claimed, dropped})
      |> add_issue(pages != [] and not contiguous?(pages), {:not_contiguous, pages})

    {segment, MapSet.union(seen, MapSet.new(pages))}
  end

  defp contiguous?(pages), do: List.last(pages) - List.first(pages) + 1 == length(pages)

  defp unassigned_segment(page) do
    %{
      pages: [page],
      kind: :unreadable,
      invoice_no: nil,
      reason: "no segment claimed this page",
      issues: [:unassigned_by_decider]
    }
  end

  @doc """
  Splits a segment wherever the pages themselves prove it holds two bills.

  Under-splitting is the model's characteristic error and it is the recoverable
  one: two supplier GSTINs, or two different printed document numbers, are facts
  on the page, so the split needs no judgement and is made rather than merely
  reported. (Over-splitting is not symmetrical — nothing on a continuation page
  proves it belongs to the page before it — so that stays a report.)
  """
  def split_on_evidence(segment, transcription, client, kind \\ :purchase)

  def split_on_evidence(%{pages: [_single]} = segment, _transcription, _client, _kind),
    do: [segment]

  def split_on_evidence(segment, transcription, client, kind) do
    groups =
      segment.pages
      |> Enum.map(&{&1, identity(transcription, &1, client, kind)})
      |> Enum.reduce([], fn {page, identity}, groups ->
        case groups do
          [%{identity: current} = group | rest] ->
            if conflict?(current, identity) do
              [%{pages: [page], identity: identity} | groups]
            else
              [%{group | pages: group.pages ++ [page], identity: merge(current, identity)} | rest]
            end

          [] ->
            [%{pages: [page], identity: identity}]
        end
      end)
      |> Enum.reverse()

    case groups do
      [_one] ->
        [segment]

      several ->
        Enum.map(several, fn group ->
          segment
          |> Map.put(:pages, group.pages)
          |> Map.put(:invoice_no, invoice_no_for(segment, group, transcription))
          |> add_issue(true, {:split_from, segment.pages})
        end)
    end
  end

  defp identity(transcription, page, client, kind) do
    features = page_features(transcription, page)

    %{
      seller: counterparty(features, client, kind),
      number: features.invoice_no
    }
  end

  # On a purchase page the one GSTIN that is not the client's is the supplier,
  # and an invoice has exactly one. On a sales page it is the customer, and a
  # single invoice may print two of them — bill-to and ship-to — so it proves
  # nothing about where one bill ends.
  defp counterparty(features, client, :purchase) do
    features.gstins_valid |> Enum.reject(&(&1 == client)) |> List.first()
  end

  defp counterparty(_features, _client, :sales), do: nil

  defp conflict?(current, identity) do
    differs?(current.seller, identity.seller) or differs?(current.number, identity.number)
  end

  defp differs?(nil, _right), do: false
  defp differs?(_left, nil), do: false
  defp differs?(left, right), do: searchable(left) != searchable(right)

  defp merge(current, identity) do
    %{seller: current.seller || identity.seller, number: current.number || identity.number}
  end

  # The model's number survives the split only for the group it is actually
  # printed on; every other group falls back to what its own pages print.
  defp invoice_no_for(segment, group, transcription) do
    claimed = segment.invoice_no

    if claimed && on_pages?(claimed, group.pages, transcription) do
      claimed
    else
      group.identity.number
    end
  end

  defp on_pages?(number, pages, transcription) do
    haystack = transcription |> Transcription.text(pages) |> searchable()
    needle = searchable(number)

    needle != "" and String.contains?(haystack, needle)
  end

  defp ground(%{invoice_no: nil} = segment, _transcription), do: Map.put(segment, :grounded?, nil)

  defp ground(segment, transcription) do
    if on_pages?(segment.invoice_no, segment.pages, transcription) do
      Map.put(segment, :grounded?, true)
    else
      correct(segment, transcription)
    end
  end

  # A number the model named that is not on the page, next to a number the page
  # does print, is not a coin flip: the page wins, and the substitution is
  # recorded. On breeze 2026-06 the cheap decider lagged a page behind itself for
  # a stretch of the packet, labelling each bill with its predecessor's number —
  # every one of those was ungrounded, and every one had the right number sitting
  # on its own page.
  defp correct(segment, transcription) do
    candidate =
      segment.pages
      |> Enum.map(&page_features(transcription, &1).invoice_no)
      |> Enum.find(& &1)

    if candidate do
      segment
      |> Map.put(:invoice_no, candidate)
      |> Map.put(:grounded?, true)
      |> add_issue(true, {:invoice_no_corrected, segment.invoice_no, candidate})
    else
      segment
      |> Map.put(:grounded?, false)
      |> add_issue(true, {:invoice_no_not_on_page, segment.invoice_no})
    end
  end

  @doc """
  The client's own GSTIN, inferred from the packet.

  It is printed on nearly every page of their own packet — as the buyer on a
  purchase pile, as the seller on a sales one — which is exactly what makes it
  identifiable without being told: it is the one GSTIN that is everywhere. (In
  production the client record already knows it, and `Nila.Gst.Extraction.Pipeline`
  passes it; this is the oracle for the same fact when nobody has.)
  """
  def client_gstin(transcription) do
    pages = Transcription.numbers(transcription)

    counts =
      pages
      |> Enum.flat_map(fn number ->
        transcription
        |> Transcription.page_text(number)
        |> Features.scan()
        |> Map.fetch!(:gstins_valid)
        |> Enum.uniq()
      end)
      |> Enum.frequencies()

    # A majority is not enough on its own: a client who bills one dominant
    # customer prints both GSTINs on every page, and `max_by` would settle that
    # tie by map order. Guessing wrong here is expensive — the repair oracle
    # would snap the client's own damaged number to the other party's — so a tie
    # returns nothing and the packet is read without the oracle.
    case counts |> Enum.sort_by(fn {_gstin, count} -> -count end) |> Enum.take(2) do
      [{gstin, count}] when count * 2 > length(pages) ->
        gstin

      [{gstin, count}, {_other, second}] when count * 2 > length(pages) and count > second ->
        gstin

      _no_clear_majority ->
        nil
    end
  end

  defp one_seller(segment, transcription, client, kind) do
    scans = Enum.map(segment.pages, &page_features(transcription, &1))

    sellers =
      case kind do
        :purchase ->
          scans |> Enum.flat_map(& &1.gstins_valid) |> Enum.reject(&(&1 == client)) |> Enum.uniq()

        :sales ->
          []
      end

    # Two bills from the *same* supplier defeat the seller check, and two
    # consecutive bills from one supplier is the commonest thing in a packet.
    # But each still prints its own number, so a segment carrying two different
    # printed document numbers is a merge whoever issued them.
    numbers = scans |> Enum.map(& &1.invoice_no) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    segment
    |> Map.put(:sellers, sellers)
    |> add_issue(length(sellers) > 1, {:multiple_sellers, sellers})
    |> add_issue(length(numbers) > 1, {:multiple_invoice_numbers, numbers})
  end

  defp page_features(transcription, number) do
    transcription |> Transcription.page_text(number) |> Features.scan()
  end

  # "Not an invoice" is the one verdict that ends a page's life: a non-invoice is
  # never extracted, never flagged and counts as accounted for in the ledger. So
  # it is the one verdict the model may propose but not settle. On breeze 2026-06
  # a single run of the decider called seven real bills non-invoices — that is
  # seven purchases deleted from a return, in silence, and no downstream check
  # would ever have looked.
  #
  # The verdict is therefore held to proof in both directions:
  #
  #   * pages carrying the evidence of an invoice (a supplier GSTIN that passes
  #     its check digit, GST wording, and a total or amount in words) are read as
  #     invoices whatever the model called them — a wasted call on a challan is
  #     cheap, a deleted purchase is not;
  #   * a non-invoice verdict is confirmed only by a printed marker of what the
  #     page actually is (challan, e-way bill, trip receipt, purchase order);
  #   * anything else — proposed non-invoice, no evidence either way — becomes
  #     `:unreadable`, which the ledger reports as an unaccounted page rather
  #     than quietly closing.
  #
  # The three genuine non-invoices in that packet (Porter trip screenshots with
  # ₹0.00 CGST and no supplier GSTIN) carry their marker and pass unchanged.
  defp confirm_kind(%{kind: :invoice} = segment, _transcription, _client, _kind), do: segment

  defp confirm_kind(segment, transcription, client, kind) do
    scans = Enum.map(segment.pages, &page_features(transcription, &1))
    invoice_evidence? = Enum.any?(scans, &invoice_evidence?(&1, client, kind))

    marker? = Enum.any?(scans, & &1.non_invoice_marker)

    cond do
      invoice_evidence? ->
        segment |> Map.put(:kind, :invoice) |> add_issue(true, {:kind_overridden, segment.kind})

      marker? ->
        segment

      true ->
        segment
        |> Map.put(:kind, :unreadable)
        |> add_issue(true, {:non_invoice_unconfirmed, segment.kind})
    end
  end

  # What counts as proof that a page really is a bill, which is the one thing
  # allowed to overturn a `non_invoice` verdict.
  #
  # On a purchase page it is a supplier: someone who charges GST is registered,
  # so a valid GSTIN that is not the client's, next to tax words and a total, is
  # a bill. On a sales page that test is inert — the counterparty is the
  # customer, and most B2C customers have no GSTIN at all — so it would quietly
  # stop rescuing exactly the bills a return must not lose. Tax words and a
  # printed total are what a sales bill has and a challan, quotation or packing
  # slip does not.
  defp invoice_evidence?(features, client, :purchase) do
    sellers = Enum.reject(features.gstins_valid, &(&1 == client))
    sellers != [] and features.tax_words? and (features.total_row? or features.words?)
  end

  defp invoice_evidence?(features, _client, :sales) do
    features.tax_words? and (features.total_row? or features.words?)
  end

  @doc "A violation as a line of English, with page numbers that print as numbers."
  def describe({:pages_unaccounted, pages}), do: "pages in no segment: #{list(pages)}"
  def describe({:pages_double_claimed, pages}), do: "pages claimed twice: #{list(pages)}"

  def describe({:segments_not_contiguous, page_lists}),
    do: "segments that skip pages: #{Enum.map_join(page_lists, "; ", &list/1)}"

  def describe({:segments_with_multiple_sellers, page_lists}),
    do: "segments naming two suppliers: #{Enum.map_join(page_lists, "; ", &list/1)}"

  def describe({:segments_with_multiple_invoice_numbers, page_lists}),
    do: "segments carrying two document numbers: #{Enum.map_join(page_lists, "; ", &list/1)}"

  def describe({:non_invoice_pages_with_invoice_evidence, page_lists}),
    do:
      "pages called non-invoice that carry a supplier GSTIN and GST wording, kept anyway: " <>
        Enum.map_join(page_lists, "; ", &list/1)

  def describe({:unconfirmed_non_invoice_pages, page_lists}),
    do:
      "pages called non-invoice with nothing on them to confirm it, left unaccounted: " <>
        Enum.map_join(page_lists, "; ", &list/1)

  def describe({:segments_split_on_evidence, page_lists}),
    do:
      "segments split where the pages proved two bills: " <>
        Enum.map_join(page_lists, "; ", &list/1)

  def describe({:invoice_numbers_corrected, corrections}),
    do: "invoice numbers replaced by what the page prints: " <> Enum.join(corrections, ", ")

  def describe({:invoice_numbers_not_grounded, numbers}),
    do: "invoice numbers not printed on their own pages: #{Enum.join(numbers, ", ")}"

  def describe(other), do: inspect(other, charlists: :as_lists, limit: 20)

  defp list(pages), do: Enum.map_join(pages, ",", &to_string/1)

  defp searchable(value) do
    value |> to_string() |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "")
  end

  defp add_issue(segment, false, _issue), do: segment
  defp add_issue(segment, true, issue), do: Map.update!(segment, :issues, &(&1 ++ [issue]))

  defp violations(segments, missing, double_claimed) do
    ungrounded = Enum.filter(segments, &(&1[:grounded?] == false))

    broken =
      Enum.filter(segments, fn segment ->
        Enum.any?(segment.issues, &match?({:not_contiguous, _}, &1))
      end)

    merged = with_issue(segments, :multiple_sellers)
    double_numbered = with_issue(segments, :multiple_invoice_numbers)
    overridden = with_issue(segments, :kind_overridden)
    unconfirmed = with_issue(segments, :non_invoice_unconfirmed)
    split = with_issue(segments, :split_from)
    corrected = with_issue(segments, :invoice_no_corrected)

    []
    |> put_violation(missing != [], {:pages_unaccounted, missing})
    |> put_violation(double_claimed != [], {:pages_double_claimed, double_claimed})
    |> put_violation(
      merged != [],
      {:segments_with_multiple_sellers, Enum.map(merged, & &1.pages)}
    )
    |> put_violation(
      double_numbered != [],
      {:segments_with_multiple_invoice_numbers, Enum.map(double_numbered, & &1.pages)}
    )
    |> put_violation(
      overridden != [],
      {:non_invoice_pages_with_invoice_evidence, Enum.map(overridden, & &1.pages)}
    )
    |> put_violation(
      unconfirmed != [],
      {:unconfirmed_non_invoice_pages, Enum.map(unconfirmed, & &1.pages)}
    )
    |> put_violation(split != [], {:segments_split_on_evidence, Enum.map(split, & &1.pages)})
    |> put_violation(
      corrected != [],
      {:invoice_numbers_corrected,
       Enum.flat_map(corrected, fn segment ->
         for {:invoice_no_corrected, from, to} <- segment.issues, do: "#{from} → #{to}"
       end)}
    )
    |> put_violation(
      ungrounded != [],
      {:invoice_numbers_not_grounded, Enum.map(ungrounded, & &1.invoice_no)}
    )
    |> put_violation(broken != [], {:segments_not_contiguous, Enum.map(broken, & &1.pages)})
  end

  defp put_violation(violations, false, _violation), do: violations
  defp put_violation(violations, true, violation), do: violations ++ [violation]

  defp with_issue(segments, name) do
    Enum.filter(segments, fn segment ->
      Enum.any?(segment.issues, fn
        {^name, _detail} -> true
        _other -> false
      end)
    end)
  end
end
