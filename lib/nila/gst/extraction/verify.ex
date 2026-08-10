defmodule Nila.Gst.Extraction.Verify do
  @moduledoc """
  Holds one extracted invoice to the page it came from, and to arithmetic.

  Two independent checks, in that order, because they catch different failures.

  **Grounding.** Every field defined as "copy what is printed" must be provably
  present in the transcription. On breeze 2026-06 the model returned a taxable
  value of 62,552 for a bill whose pages contain no such number anywhere — the
  real figure was 64,552 — and every downstream check passed, because a
  fabricated number is internally consistent with nothing to contradict it. A
  reconcile check on ungrounded values is checking fiction. Grounding is cheap
  and total here only because the pipeline reasons over text: on pixels there is
  nothing to string-search.

  **Arithmetic.** GST invoices are overdetermined — lines sum to the taxable
  value, tax is a percentage of it, CGST equals SGST, the grand total is their
  sum, and the amount in words repeats it. Any single wrong number therefore
  disagrees with a coherent majority, which is enough to say *which* number is
  wrong rather than only that something is.

  That distinction is the point of `:internally_inconsistent_bill`. The same
  breeze packet holds a bill whose own printed TOTAL says 275,000 while its
  lines sum to 64,552, its tax is 18% of 64,552, and its grand total is
  64,552 + tax. The bill is wrong, not the extraction — a re-read cannot fix it
  and a silent "closest match" hides it. So the flag names the outlier and shows
  the coherent subset, and a human decides.
  """

  alias Nila.Gstin

  @tolerance 1.0
  @tight_tolerance 0.02

  @printed_money ~w(printed_subtotal_before_discount printed_discount_amount
                    printed_total_taxable printed_cgst printed_sgst printed_igst
                    printed_total_tax printed_additional_charges
                    printed_rounding_adjustment printed_grand_total)

  @doc """
  Verifies one invoice map against the text of its own pages.

  Returns `%{status:, checks:, flags:}` where status is `:verified`,
  `:flagged` or `:unverifiable` (nothing printed to check against — surfaced,
  never quietly accepted).
  """
  def invoice(data, text, repairs \\ []) when is_map(data) and is_binary(text) do
    haystack = normalize_text(text)

    checks =
      grounding_checks(data, haystack, repaired_from(repairs)) ++
        arithmetic_checks(data, reverse_charge?(text)) ++ gstin_checks(data)

    flags = flags(data, checks, haystack)

    %{status: status(data, checks, flags), checks: checks, flags: flags}
  end

  # ---- grounding ----

  # A value an earlier stage repaired is grounded against what the page actually
  # printed, not against the corrected form. Otherwise the two guards fight: the
  # repair replaces a scan-damaged GSTIN with the only legal reading of it, and
  # grounding then objects that the legal reading is not on the page — which is
  # the whole reason it needed repairing. The evidence is the damaged string plus
  # the check digit, and that evidence is what gets checked.
  defp repaired_from(repairs) do
    Map.new(repairs, fn repair -> {repair["field"], repair["from"]} end)
  end

  defp grounding_checks(data, haystack, repaired) do
    money =
      @printed_money
      |> Enum.map(&{&1, data[&1]})
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)
      |> Enum.map(fn {field, value} ->
        cond do
          printed?(value, haystack) ->
            check(:grounding, field, true, %{value: value})

          derived_total_tax?(field, value, data, haystack) ->
            check(:grounding, field, true, %{value: value, derived_from: "cgst + sgst + igst"})

          true ->
            check(:grounding, field, false, %{value: value})
        end
      end)

    identifiers =
      [
        {"invoice_number", data["invoice_number"]},
        {"seller.gstin", get_in(data, ["seller", "gstin"])},
        {"buyer.gstin", get_in(data, ["buyer", "gstin"])}
      ]
      |> Enum.reject(fn {_field, value} -> is_nil(value) or value == "" end)
      |> Enum.map(fn {field, value} ->
        case repaired[field] do
          nil ->
            check(:grounding, field, alphanumeric_present?(value, haystack), %{value: value})

          printed ->
            check(:grounding, field, alphanumeric_present?(printed, haystack), %{
              value: value,
              repaired_from: printed
            })
        end
      end)

    money ++ identifiers
  end

  # Many bills print CGST and SGST and no combined figure, so a total tax that is
  # the sum of its own printed halves is a derivation, not an invention —
  # breeze 2026-06 pages 13 and 21 print 289.83 and 109.80 twice over and no
  # total. Grounding exists to catch values with no support on the page, so it
  # accepts this one narrowly: total tax only, only from components that are
  # themselves grounded, and the derivation is recorded on the check rather than
  # waved through. Every other printed_* field still has to be on the page —
  # notably the taxable value, which is where the fabrication was found.
  defp derived_total_tax?("printed_total_tax", value, data, haystack) do
    components = ["printed_cgst", "printed_sgst", "printed_igst"]
    present = Enum.filter(components, &is_number(data[&1]))

    present != [] and
      Enum.all?(present, &printed?(data[&1], haystack)) and
      close?(Enum.reduce(present, 0.0, fn field, acc -> acc + num(data[field]) end), value)
  end

  defp derived_total_tax?(_field, _value, _data, _haystack), do: false

  @doc """
  Whether a money value is printed in the given text.

  Digit-boundary matched, so 552 does not "appear" inside 164,552 — a looser
  search would let a fabricated number borrow its own digits from a neighbour.
  """
  def printed?(value, haystack) when is_number(value) do
    haystack = normalize_text(haystack)

    value
    |> variants()
    |> Enum.any?(fn variant ->
      Regex.match?(~r/(?<![0-9.])#{Regex.escape(variant)}(?![0-9])/, haystack)
    end)
  end

  def printed?(_value, _haystack), do: false

  defp variants(value) do
    absolute = abs(value / 1)
    rounded = Float.round(absolute, 2)
    whole = trunc(rounded)

    base =
      if rounded == whole * 1.0 do
        ["#{whole}", "#{whole}.00", "#{whole}.0", "#{whole}.-"]
      else
        [:erlang.float_to_binary(rounded, decimals: 2)]
      end

    Enum.uniq(base)
  end

  defp alphanumeric_present?(value, haystack) do
    needle = value |> to_string() |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "")
    stripped = String.replace(haystack, ~r/[^0-9A-Z]/, "")

    needle != "" and String.contains?(stripped, needle)
  end

  # Commas and spaces inside numbers are typography, not data; the rest of the
  # page is left alone so digit boundaries still mean something.
  defp normalize_text(text) do
    text
    |> String.upcase()
    |> String.replace(~r/(?<=\d)[,\s](?=\d)/, "")
    |> String.replace(~r/(?<=\d)\s+(?=\.)/, "")
  end

  # ---- arithmetic ----

  defp arithmetic_checks(data, reverse_charge?) do
    lines = data["line_items"] || []
    lines_sum = sum(lines, "taxable_value")
    taxable = data["printed_total_taxable"]
    cgst = data["printed_cgst"]
    sgst = data["printed_sgst"]
    igst = data["printed_igst"]
    total_tax = data["printed_total_tax"]
    grand = data["printed_grand_total"]

    []
    |> maybe_check(
      lines != [] and is_number(taxable),
      :arithmetic,
      "lines_sum_vs_printed_taxable",
      close?(lines_sum, taxable),
      %{lines_sum: lines_sum, printed: taxable}
    )
    |> maybe_check(
      is_number(cgst) and is_number(sgst),
      :arithmetic,
      "cgst_equals_sgst",
      close?(cgst, sgst, @tight_tolerance),
      %{cgst: cgst, sgst: sgst}
    )
    |> maybe_check(
      is_number(total_tax) and Enum.any?([cgst, sgst, igst], &is_number/1),
      :arithmetic,
      "tax_components_sum",
      close?(num(cgst) + num(sgst) + num(igst), total_tax),
      %{components: num(cgst) + num(sgst) + num(igst), printed: total_tax}
    )
    |> maybe_check(
      is_number(grand) and is_number(taxable),
      :arithmetic,
      "grand_total",
      close?(computed_grand_total(data, reverse_charge?), grand),
      %{
        computed: computed_grand_total(data, reverse_charge?),
        printed: grand,
        reverse_charge: reverse_charge?
      }
    )
    |> maybe_check(
      is_number(taxable) and is_number(total_tax) and implied_rate(lines) != nil,
      :arithmetic,
      "tax_is_rate_times_taxable",
      close?(num(taxable) * num(implied_rate(lines)) / 100, num(total_tax), 2.0),
      %{rate: implied_rate(lines), on: taxable, printed: total_tax}
    )
  end

  # Under reverse charge the supplier does not collect the tax — the recipient
  # pays it to the government — so the bill's own total excludes it. Freight and
  # legal fees are routinely RCM, so an invariant that always adds tax to the
  # total does not merely misfire here, it misfires on a whole category of real
  # purchases, and a check that cries wolf on a category is a check nobody reads.
  defp computed_grand_total(data, reverse_charge?) do
    tax = if reverse_charge?, do: 0.0, else: num(data["printed_total_tax"])

    num(data["printed_total_taxable"]) + tax +
      num(data["printed_additional_charges"]) + num(data["printed_rounding_adjustment"])
  end

  # Read from the page, because the page says so in words. The negative form is
  # checked first and beats the positive one: nearly every Tally invoice prints
  # "Whether tax is payable under reverse charge : No", and a naive search for
  # the phrase would declare the entire corpus reverse-charge.
  @rcm_negative ~r/reverse\s+charge[^\n]{0,40}?[:\s]\s*(no|nil|n)\b/i
  @rcm_positive ~r/payable\s+by\s+the\s+(service\s+)?recipient|under\s+(the\s+)?reverse[\s-]+charge\s+mechanism|reverse[\s-]+charge[^\n]{0,25}\b(yes|applicable)\b|\brcm\b/i

  @doc "Whether the page declares this a reverse-charge supply."
  def reverse_charge?(text) when is_binary(text) do
    Regex.match?(@rcm_positive, text) and not Regex.match?(@rcm_negative, text)
  end

  @credit_note ~r/(?:^|\n)[\s|#>*_-]*(?:tax\s+)?credit\s+note(?:\s*(?:no\.?|number)?\s*[:#-]?\s*[A-Z0-9][^\n]*)?\s*(?:\||$)/im
  @debit_note ~r/(?:^|\n)[\s|#>*_-]*(?:tax\s+)?debit\s+note(?:\s*(?:no\.?|number)?\s*[:#-]?\s*[A-Z0-9][^\n]*)?\s*(?:\||$)/im
  @export ~r/\b(export\s+invoice|letter\s+of\s+undertaking|\bLUT\b|special\s+economic\s+zone|\bSEZ\b|supply\s+meant\s+for\s+export)\b|\b(USD|EUR|GBP|AED|SGD)\s*[\d.,]/i

  @doc """
  What kind of document the page says it is, read off the page and nothing else.

  These are the shapes `Nila.Gst.Sales.Gstr1.derive/2` has no table for — a
  credit note has no `cdnr`, an export has no `exp`, an outward reverse-charge
  supply is filed `rchrg: "N"` regardless. Deriving one of them anyway files a
  number that is wrong in a way no arithmetic check can see: a ₹50,000 credit
  note becomes a ₹50,000 sale, and the liability is out by ₹100,000.

  So they are detected here, where the text is, and refused at sign-off. Nothing
  in six filed months across both clients is any of these; the day one arrives,
  a human is told rather than a return being quietly built around it.

  ## A false positive here is a month nobody can file or fix

  These markers are page-wide regex, not a classification of the document, and
  they gate `blocking` issues (`Gstr1.blocking_issues/1`) that no confirmation
  clears. That is deliberate for a real credit note. But the patterns match
  anywhere on the page: "no credit notes after 7 days" in a terms footer reads
  as a credit note, and `@export` fires on a bare `LUT` or on `USD 1,200` quoted
  as a reference price on a domestic bill.

  When that happens the month is stuck. `unsupported_document_issues/1` names
  `invoice_number` in its `"fields"`, which is not what is wrong, and
  `blocking_issues/1` is not part of the `correction_issues` list that feeds
  `Gstr1.flagged_fields/2` (see `Sales.Workings.materialize/5`) — so no field is
  correctable, the blocker cannot be confirmed, and there is no third way out.
  `b2c_supply_unsupported` escapes only because `buyer_gstin` happens to be
  flagged by a different check.

  The fix is not a wider `@correctable_*` list: the thing a reviewer would
  correct is the document classification, not a field on the invoice. That wants
  its own resolution verb (a `reclassify_document` alongside
  `exclude_duplicate_copy`), so the override is an audited event naming what was
  read and what it actually is. Until then, a misread marker needs a database
  edit, and that is the real cost of these patterns being this loose.
  """
  def document_markers(text) when is_binary(text) do
    %{
      "credit_note" => Regex.match?(@credit_note, text),
      "debit_note" => Regex.match?(@debit_note, text),
      "export" => Regex.match?(@export, text),
      "reverse_charge" => reverse_charge?(text)
    }
  end

  defp gstin_checks(data) do
    [
      {"seller.gstin", get_in(data, ["seller", "gstin"])},
      {"buyer.gstin", get_in(data, ["buyer", "gstin"])}
    ]
    |> Enum.reject(fn {_field, value} -> is_nil(value) or value == "" end)
    |> Enum.map(fn {field, value} ->
      check(:gstin, field, Gstin.valid?(value), %{value: value})
    end)
  end

  # The rate every line agrees on, if they do. A mixed-rate invoice has no single
  # rate and the check that uses this is simply skipped rather than guessed at.
  defp implied_rate(lines) do
    rates =
      lines
      |> Enum.map(fn line ->
        num(line["igst_rate"]) + num(line["cgst_rate"]) + num(line["sgst_rate"])
      end)
      |> Enum.reject(&(&1 == 0))
      |> Enum.uniq()

    case rates do
      [rate] -> rate
      _mixed_or_none -> nil
    end
  end

  # ---- flags ----

  defp flags(data, checks, haystack) do
    ungrounded = Enum.filter(checks, &(&1.kind == :grounding and not &1.ok?))
    failed_arithmetic = Enum.filter(checks, &(&1.kind == :arithmetic and not &1.ok?))

    []
    |> add(ungrounded != [], fn ->
      {:value_not_on_page, Enum.map(ungrounded, & &1.field)}
    end)
    |> add(failed_arithmetic != [] and ungrounded == [], fn ->
      inconsistency(data, haystack) ||
        {:arithmetic_mismatch, Enum.map(failed_arithmetic, & &1.field)}
    end)
    |> Enum.concat(gstin_flags(checks))
  end

  defp gstin_flags(checks) do
    case Enum.filter(checks, &(&1.kind == :gstin and not &1.ok?)) do
      [] -> []
      bad -> [{:invalid_gstin, Enum.map(bad, & &1.detail.value)}]
    end
  end

  # Which printed number is the outlier? Three independent routes to the taxable
  # value — the line items, the grand total less tax, and the tax at its own rate.
  # When at least two of them agree with each other and disagree with what the
  # bill prints as its total, the bill's printed total is the wrong one, and it
  # is named rather than quietly replaced.
  defp inconsistency(data, haystack) do
    printed = data["printed_total_taxable"]

    if is_number(printed) and printed?(printed, haystack) do
      candidates = taxable_candidates(data)

      case consensus(candidates) do
        {value, agreeing} when length(agreeing) >= 2 ->
          if close?(value, printed) do
            nil
          else
            {:internally_inconsistent_bill,
             %{
               field: "printed_total_taxable",
               printed: printed,
               implied: Float.round(value / 1, 2),
               agreeing: Enum.map(agreeing, &elem(&1, 0))
             }}
          end

        _no_consensus ->
          nil
      end
    end
  end

  defp taxable_candidates(data) do
    lines = data["line_items"] || []
    lines_sum = sum(lines, "taxable_value")
    total_tax = data["printed_total_tax"]
    grand = data["printed_grand_total"]
    rate = implied_rate(lines)

    [
      {"line_items", if(lines != [] and lines_sum > 0, do: lines_sum)},
      {"grand_total_less_tax",
       if(is_number(grand) and is_number(total_tax),
         do:
           grand - total_tax - num(data["printed_additional_charges"]) -
             num(data["printed_rounding_adjustment"])
       )},
      {"tax_at_printed_rate",
       if(is_number(total_tax) and is_number(rate) and rate > 0, do: total_tax * 100 / rate)}
    ]
    |> Enum.reject(fn {_source, value} -> is_nil(value) end)
  end

  # The largest mutually-agreeing group of candidates, and its value.
  defp consensus([]), do: nil

  defp consensus(candidates) do
    candidates
    |> Enum.map(fn {_source, value} ->
      agreeing = Enum.filter(candidates, fn {_s, other} -> close?(other, value) end)
      {value, agreeing, length(agreeing)}
    end)
    |> Enum.max_by(fn {_value, _agreeing, count} -> count end)
    |> then(fn {value, agreeing, _count} -> {value, agreeing} end)
  end

  # ---- status ----

  defp status(data, checks, flags) do
    cond do
      Enum.any?(flags, &match?({:value_not_on_page, _}, &1)) -> :flagged
      Enum.any?(checks, &(&1.kind == :arithmetic and not &1.ok?)) -> :flagged
      Enum.any?(flags, &match?({:invalid_gstin, _}, &1)) -> :flagged
      nothing_to_check?(data, checks) -> :unverifiable
      true -> :verified
    end
  end

  # An invoice with no printed totals at all cannot be verified by any of this;
  # calling it verified would launder "we did not look" into "we checked".
  defp nothing_to_check?(data, checks) do
    Enum.all?(@printed_money, &is_nil(data[&1])) or
      not Enum.any?(checks, &(&1.kind == :arithmetic))
  end

  # ---- helpers ----

  defp check(kind, field, ok?, detail), do: %{kind: kind, field: field, ok?: ok?, detail: detail}

  defp maybe_check(checks, false, _kind, _field, _ok?, _detail), do: checks

  defp maybe_check(checks, true, kind, field, ok?, detail),
    do: checks ++ [check(kind, field, ok?, detail)]

  defp add(flags, false, _build), do: flags
  defp add(flags, true, build), do: flags ++ [build.()]

  defp sum(lines, key), do: Enum.reduce(lines, 0.0, fn line, acc -> acc + num(line[key]) end)

  defp num(value) when is_number(value), do: value / 1
  defp num(_value), do: 0.0

  defp close?(a, b, tolerance \\ @tolerance)
  defp close?(a, b, tolerance) when is_number(a) and is_number(b), do: abs(a - b) <= tolerance
  defp close?(_a, _b, _tolerance), do: false
end
