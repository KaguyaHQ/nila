defmodule Nila.Gst.Extraction.Discovery.PageLabels do
  @moduledoc """
  Labels each page locally — `start` | `continuation` | `non_invoice` —
  and lets code stitch the labels into segments.

  The alternative shape, one call that reads the whole packet and emits the
  finished segmentation, has a failure that is structural rather than fixable.
  Its output is a global object: every boundary is expressed relative to every
  other, so one wobble reshuffles the rest. Measured on breeze 2026-06 at
  temperature 0, three runs gave three different segmentations — bills merged in
  one run and split in the next, and in one run seven real invoices called
  non-invoices. Small output protects against truncation, not against that.

  And the input grows without bound. The corpus already holds 43- and 57-page
  months, so a whole-dump decider is asked to hold more context to make each
  decision precisely as the decisions get more numerous — while the decision
  itself stays local. Whether page 31 starts a new bill depends on pages 30–32:
  a fresh header and number, whether the page before it closed with totals.
  Page 3 cannot inform that and can only distract from it.

  So each page is judged with its immediate neighbours and nothing else. The
  context a decision sees is constant whether the dump is 28 pages or 300; the
  calls are small, cheap and parallel; a retry re-judges one page rather than a
  month; and a disagreement between runs is one page's label instead of a
  reshuffled packet. Multi-page bills still work, because `continuation` chains
  link by link, and every link is local.

  This is also, not coincidentally, the shape commercial document splitters have
  used for a decade. The reason to adopt it here is the log above, not the
  precedent.
  """

  alias Nila.Gst.Extraction.Discovery.Features
  alias Nila.Gst.Extraction.Providers.MistralChat
  alias Nila.Gst.Extraction.Transcription

  @neighbours 1
  @page_char_limit 4_000
  @max_concurrency 4

  @doc "Pages of context on each side of the page being judged."
  def neighbours, do: @neighbours

  @doc "The JSON schema one page's verdict is constrained to."
  def schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["label", "invoice_no", "reason"],
      properties: %{
        label: %{
          type: "string",
          enum: ["start", "continuation", "non_invoice", "unreadable"],
          description:
            "start: this page begins a new bill. continuation: this page carries on the bill that began on an earlier page — same supplier, item table continuing, no new document number. non_invoice: a delivery challan, e-way bill, transport trip receipt, purchase order, payment slip, blank or separator page. unreadable: too garbled to tell."
        },
        invoice_no: %{
          anyOf: [%{type: "string"}, %{type: "null"}],
          description:
            "The document number exactly as printed on THIS page, or null. Never copy one from a neighbouring page and never invent one."
        },
        reason: %{anyOf: [%{type: "string"}, %{type: "null"}], description: "Short note."}
      }
    }
  end

  @doc """
  The instruction block, hashed into the cache key by callers.

  Two variants, because the two piles are mirror images. On a purchase pile the
  supplier changes with every bill and is the strongest boundary signal there
  is; on a sales pile the supplier is the client and never changes, so the same
  sentence would say "continuation" about every page in the packet. What varies
  on a sales pile is the customer and the document number.

  The purchase text is byte-identical to what it always was, so cached decisions
  stay valid and the measured runs still describe the code.
  """
  def prompt(kind \\ :purchase)

  def prompt(:purchase) do
    """
    You are labelling ONE page of a scanned packet of Indian GST bills. The \
    packet is in scan order. You are shown the page to judge, marked JUDGE THIS \
    PAGE, with its neighbouring pages for context only.

    Answer only about the marked page.

    - "start" if this page begins a new bill: its own document number, or a \
    fresh header with an item table beginning again at row 1.
    - "continuation" if it carries on a bill that began on an earlier page: the \
    same supplier, the item table running on, no new document number of its own. \
    A page headed "Page 2" of the same supplier and number as the page before it \
    is a continuation.
    - Two bills from the same supplier look nearly identical apart from the \
    number and date. A different document number from the previous page means \
    "start", however alike the pages look.
    - A page naming a different supplier from the previous page is always \
    "start", never "continuation".
    - "non_invoice" for a delivery challan, e-way bill, transport trip receipt, \
    purchase order, payment slip, blank or separator page. Judge by what the \
    document charges, not by its title: a "TAX INVOICE CUM DELIVERY CHALLAN" is \
    a bill, and a transport operator's consignment note charging GST is a bill. \
    A trip receipt showing 0.00 tax and no supplier GSTIN is not.
    - invoice_no must be printed on the marked page itself. If it is not there, \
    return null, even when a neighbouring page shows one.
    """
  end

  def prompt(:sales) do
    """
    You are labelling ONE page of a scanned packet of Indian GST bills that one \
    business issued to its customers. The packet is in scan order. You are shown \
    the page to judge, marked JUDGE THIS PAGE, with its neighbouring pages for \
    context only.

    Answer only about the marked page.

    - Every page in this packet carries the same seller — the business whose \
    packet it is. The seller is therefore NO evidence either way. Judge by the \
    document number, the customer, and whether the item table starts again.
    - "start" if this page begins a new bill: its own document number, or a \
    fresh header with an item table beginning again at row 1.
    - "continuation" if it carries on a bill that began on an earlier page: the \
    item table running on, no new document number of its own. A page headed \
    "Page 2" carrying the same number as the page before it is a continuation.
    - A different document number from the previous page means "start", however \
    alike the two pages look. Consecutive bills to the SAME customer are \
    ordinary; they are still two bills.
    - One bill may name two customers — "bill to" and "ship to" are the same \
    document. Two names alone do not make two bills; a second document number \
    does.
    - Credit notes and debit notes the business issued are bills, not \
    "non_invoice": label them "start" and copy their own number.
    - "non_invoice" for a delivery challan or packing slip carrying no tax, a \
    quotation, proforma invoice, purchase order, e-way bill printed on its own \
    page, payment receipt, blank or separator page. Judge by what the document \
    charges, not by its title: a "TAX INVOICE CUM DELIVERY CHALLAN" is a bill.
    - invoice_no must be printed on the marked page itself. If it is not there, \
    return null, even when a neighbouring page shows one.
    """
  end

  @doc """
  Labels every page, in parallel, returning `{:ok, [%{page:, response:}]}`.

  Raw responses, in page order — the mapping is pure and runs at score time, so
  the eval caches these bytes and re-runs the stitcher for free.

  `:on_page` is called with `{done, total}` as each label lands.
  """
  def request_all(%Transcription{} = transcription, opts \\ []) do
    numbers = Transcription.numbers(transcription)

    report = Keyword.get(opts, :on_page) || fn _done, _total -> :ok end
    total = length(numbers)

    numbers
    |> Task.async_stream(
      fn number -> {number, contained(fn -> request_page(transcription, number, opts) end)} end,
      max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
      timeout: :infinity,
      ordered: true
    )
    |> Stream.with_index(1)
    |> Enum.map(fn {{:ok, {number, result}}, done} ->
      report.(done, total)

      case result do
        {:ok, response} -> %{page: number, response: response}
        {:error, reason} -> %{page: number, error: reason}
      end
    end)
    |> then(&{:ok, &1})
  end

  # A raise inside an `async_stream` child reaches the caller as an exit, which no
  # `try/rescue` up the stack can catch — the audit row would stay open and the
  # dump would sit in `extracting` forever. Contained here, the stage returns a
  # regular infrastructure error and cannot misclassify the page.
  defp contained(call) do
    try do
      call.()
    rescue
      error -> {:error, {:page_label_crashed, Exception.message(error)}}
    catch
      kind, value -> {:error, {:page_label_crashed, inspect({kind, value})}}
    end
  end

  @doc "One page's call."
  def request_page(transcription, number, opts \\ []) do
    messages = [
      %{role: "system", content: "You label pages of scanned packets. You answer only in JSON."},
      %{
        role: "user",
        content:
          prompt(Keyword.get(opts, :kind, :purchase)) <>
            "\n\n" <> context_block(transcription, number)
      }
    ]

    MistralChat.request_raw(messages, "nila_page_label", schema(), opts)
  end

  @doc "Decodes labelled pages into `{:ok, [%{page:, label:, invoice_no:}]}`."
  def map_responses(responses) do
    responses
    |> Enum.reduce_while({:ok, []}, fn response, {:ok, labels} ->
      case map_response(response) do
        {:ok, label} -> {:cont, {:ok, [label | labels]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, labels} -> {:ok, Enum.reverse(labels)}
      error -> error
    end
  end

  defp map_response(%{page: page, error: reason}),
    do: {:error, {:page_label_failed, page, reason}}

  defp map_response(%{page: page, response: response}) do
    case MistralChat.decode(response) do
      {:ok, content, usage} ->
        {:ok,
         %{
           page: page,
           label: label(content["label"]),
           invoice_no: blank_to_nil(content["invoice_no"]),
           reason: blank_to_nil(content["reason"]),
           usage: usage
         }}

      {:error, reason} ->
        {:error, {:page_label_failed, page, reason}}
    end
  end

  defp label("start"), do: :start
  defp label("continuation"), do: :continuation
  defp label("non_invoice"), do: :non_invoice
  defp label(_other), do: :unreadable

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  @doc """
  Stitches labels into segments, in code.

  A `continuation` with nothing open is the one label that cannot be honoured;
  it becomes a start and says so, because the alternative is a page belonging to
  no segment. Everything the stitcher produces then goes through the same guards
  as any other decider's output — conservation, contiguity, grounding, one
  seller, one document number — which is the point of stitching deterministically
  rather than asking for the finished answer.
  """
  def stitch(labels) do
    labels
    |> Enum.sort_by(& &1.page)
    |> Enum.reduce([], fn label, segments ->
      case {label.label, segments} do
        {:continuation, [%{kind: :invoice} = open | rest]} ->
          [%{open | pages: open.pages ++ [label.page]} | rest]

        {:continuation, segments} ->
          [
            new_segment(label, :invoice, [{:continuation_without_start, label.page}])
            | segments
          ]

        {:start, segments} ->
          [new_segment(label, :invoice, []) | segments]

        {kind, segments} ->
          [new_segment(label, kind, []) | segments]
      end
    end)
    |> Enum.reverse()
  end

  defp new_segment(label, kind, issues) do
    %{
      pages: [label.page],
      kind: kind,
      invoice_no: label.invoice_no,
      reason: label.reason,
      issues: issues
    }
  end

  defp context_block(transcription, number) do
    (number - @neighbours)..(number + @neighbours)//1
    |> Enum.filter(&(Transcription.page_text(transcription, &1) != ""))
    |> Enum.map_join("\n\n", fn page ->
      text = Transcription.page_text(transcription, page)

      heading =
        if page == number, do: "JUDGE THIS PAGE — page #{page}", else: "context — page #{page}"

      """
      === #{heading} ===
      signals: #{text |> Features.scan() |> Features.summary()}
      #{clip(text, page == number)}
      """
    end)
  end

  # Context pages are there to answer "did the previous bill close" and "is this
  # the same supplier", which the head of a page answers; the page being judged
  # is shown in full.
  defp clip(text, judged?) do
    limit = if judged?, do: @page_char_limit, else: div(@page_char_limit, 3)

    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "\n… [truncated]"
    else
      text
    end
  end
end
