defmodule Nila.Gst.Hsn.DescriptionSignal do
  @moduledoc """
  Whether an invoice line's own wording looks like the HSN code it was filed
  under — computed, measured, and **rendered nowhere**.

  Phase 1 demoted `hsn_new_code` to advisory on the explicit condition that real
  risks get real checks. This is the first of those: each line already carries
  both the vendor's wording (`description`) and the portal directory's official
  wording (`hsn_description`), and nothing compared them.

  ## Why this ships dark

  Official wording is legalistic and invoice descriptions are colloquial. "AC
  service" against "Maintenance and repair services of machinery and equipment"
  has near-zero token overlap and is entirely correct. A false conflict raised at
  `required` would withhold a filing over a naming style — precisely the
  ritual-clearing failure the severity split was written to prevent.

  So the staging is deliberate and the order is not negotiable:

    1. **Shadow** (here). Compute, emit telemetry, render nothing.
    2. **Advisory.** Only once precision is demonstrated on reviewed months.
    3. **Required.** Only on measured high precision, and only then does it take
       over `hsn_implausible`'s gating role on the purchase track.

  `score/2` is intentionally crude: this stage exists to find out whether a
  cheap signal separates anything, not to be right. Judging it needs the
  telemetry, not a better algorithm written on a hunch.

  Emits `[:nila, :gst, :hsn, :description_signal]` per scored line, carrying the
  score and the two wordings, so a run over the corpus can be scored against
  months a human already reviewed.
  """

  @event [:nila, :gst, :hsn, :description_signal]

  # Words that carry no discriminating power between an invoice line and a
  # tariff heading. Kept short on purpose — a long hand-tuned list is a model
  # fitted to the examples someone happened to look at.
  #
  # "parts", "service(s)" and the like are NOT here: they are the only words
  # some short invoice lines have, and filtering them turned "AC service" into
  # nothing to compare rather than a low score. A word that is common is still
  # evidence; a word that is grammatical filler is not.
  @stopwords ~w(and or of the a an for to with in on at by other others not
                elsewhere specified including included nes)

  # Tariff headings and invoice lines inflect the same root differently —
  # "refrigeration unit" against "parts of refrigerating equipment" shares no
  # exact token and is obviously the same thing. Comparing on a crude prefix
  # catches that without pulling in a stemmer.
  @stem_length 5

  @doc """
  Scores every line of every invoice and emits telemetry. Returns the invoices
  unchanged — nothing about this is visible to a reviewer yet.
  """
  def observe(invoices, metadata \\ %{}) do
    for invoice <- List.wrap(invoices),
        line <- List.wrap(invoice["line_items"]),
        result = score_line(line) do
      :telemetry.execute(
        @event,
        %{score: result.score, shared: result.shared},
        Map.merge(metadata, %{
          code: line["hsn_sac"],
          printed: result.printed,
          official: result.official,
          invoice: invoice["invoice_number"]
        })
      )
    end

    invoices
  end

  @doc """
  The overlap between a line's own wording and the official wording of its code.

  `nil` when there is nothing to compare — no code, no official description, or
  no usable words left after stopwords. A missing signal is not a zero score.
  """
  def score_line(line) do
    with printed when is_binary(printed) <- line["description"],
         official when is_binary(official) <- line["hsn_description"],
         printed_tokens = tokens(printed),
         official_tokens = tokens(official),
         true <- printed_tokens != [] and official_tokens != [] do
      printed_stems = printed_tokens |> Enum.map(&stem/1) |> MapSet.new()
      official_stems = official_tokens |> Enum.map(&stem/1) |> MapSet.new()
      shared = MapSet.intersection(printed_stems, official_stems)

      %{
        printed: printed,
        official: official,
        shared: MapSet.size(shared),
        score: MapSet.size(shared) / MapSet.size(printed_stems)
      }
    else
      _nothing_to_compare -> nil
    end
  end

  @doc "The telemetry event this stage emits, for a handler to attach to."
  def event, do: @event

  defp tokens(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9 ]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @stopwords or String.length(&1) < 2))
  end

  defp stem(token), do: String.slice(token, 0, @stem_length)
end
