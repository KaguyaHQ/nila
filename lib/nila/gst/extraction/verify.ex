defmodule Nila.Gst.Extraction.Verify do
  @moduledoc """
  Holds one extracted invoice to the page it came from, and to arithmetic.

  Two independent checks, in that order, because they catch different failures.

  **Source presence.** Every field defined as "copy what is printed" must have
  its value somewhere in the transcription. On breeze 2026-06 the model returned
  a taxable value of 62,552 for a bill whose pages contain no such number anywhere
  — the real figure was 64,552 — and every downstream check passed, because a
  fabricated number is internally consistent with nothing to contradict it.
  This check proves only numeric presence. It does not infer a field's meaning
  from vendor vocabulary; the structuring model sees headings and table geometry,
  while arithmetic below can prove or contradict exact accounting relationships.

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

  alias Nila.Gst.Extraction.LineAmounts
  alias Nila.Gstin

  @tolerance 1.0
  @tight_tolerance 0.02

  @printed_money ~w(printed_subtotal_before_discount printed_discount_amount
                    printed_total_taxable printed_cgst printed_sgst printed_igst
                    printed_total_tax printed_additional_charges
                    printed_rounding_adjustment printed_grand_total)
  @source_line_numbers ~w(quantity printed_unit_price discount_rate discount_amount
                          printed_line_amount printed_line_total printed_taxable_value
                          cgst_rate cgst_amount sgst_rate sgst_amount igst_rate igst_amount)

  @doc """
  Verifies one invoice map against the text of its own pages.

  Returns `%{status:, checks:, flags:}` where status is `:verified`,
  `:flagged` or `:unverifiable` (nothing printed to check against — surfaced,
  never quietly accepted).
  """
  def invoice(data, text, repairs \\ []) when is_map(data) and is_binary(text) do
    haystack = normalize_text(text)

    checks =
      source_presence_checks(data, haystack, repaired_from(repairs)) ++
        arithmetic_checks(data, reverse_charge?(text)) ++ gstin_checks(data)

    flags = flags(data, checks, haystack)

    %{status: status(data, checks, flags), checks: checks, flags: flags}
  end

  @doc "Runs checks that need structured values but no independent OCR transcription."
  def structured(data, reverse_charge? \\ false) when is_map(data) do
    checks = arithmetic_checks(data, reverse_charge?) ++ gstin_checks(data)
    flags = flags(data, checks, "")

    status =
      case status(data, checks, flags) do
        :verified -> :unverifiable
        status -> status
      end

    %{status: status, checks: checks, flags: flags}
  end

  @doc "Removes extracted numeric candidates whose values do not occur in the source."
  def discard_unobserved_values(data, checks) when is_map(data) and is_list(checks) do
    fields =
      checks
      |> Enum.filter(&failed_source_presence?/1)
      |> Enum.map(&check_field/1)
      |> Enum.filter(&source_numeric_field?/1)
      |> Enum.uniq()

    {data, repairs} =
      Enum.reduce(fields, {data, []}, fn field, {current, repairs} ->
        case field_value(current, field) do
          nil ->
            {current, repairs}

          value ->
            repair = %{
              "field" => field,
              "from" => value,
              "to" => nil,
              "basis" => "value_absent_from_source"
            }

            {clear_field(current, field), repairs ++ [repair]}
        end
      end)

    {data, repairs}
  end

  # ---- source presence ----

  # A value an earlier stage repaired is checked against what the page actually
  # printed, not against the corrected form. Otherwise the two guards fight: the
  # repair replaces a scan-damaged GSTIN with the only legal reading of it, and
  # source presence then objects that the legal reading is not on the page — which
  # is the whole reason it needed repairing. The evidence is the damaged string
  # plus the check digit, and that evidence is what gets checked.
  defp repaired_from(repairs) do
    Map.new(repairs, fn repair -> {repair["field"], repair["from"]} end)
  end

  defp source_presence_checks(data, haystack, repaired) do
    money =
      @printed_money
      |> Enum.map(&{&1, data[&1]})
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)
      |> Enum.map(fn {field, value} ->
        check(:source_presence, field, printed?(value, haystack), %{value: value})
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
            check(:source_presence, field, alphanumeric_present?(value, haystack), %{value: value})

          printed ->
            check(:source_presence, field, alphanumeric_present?(printed, haystack), %{
              value: value,
              repaired_from: printed
            })
        end
      end)

    line_money =
      data
      |> Map.get("line_items", [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, index} ->
        @source_line_numbers
        |> Enum.map(&{&1, line[&1]})
        |> Enum.reject(fn {_field, value} -> is_nil(value) end)
        |> Enum.map(fn {field, value} ->
          check(
            :source_presence,
            "line_items[#{index}].#{field}",
            printed?(value, haystack),
            %{value: value}
          )
        end)
      end)

    money ++ line_money ++ identifiers
  end

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
        [
          :erlang.float_to_binary(rounded, decimals: 2),
          :erlang.float_to_binary(rounded, [:compact, decimals: 2])
        ]
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
    lines_sum = sum_taxable(lines)
    taxable = data["printed_total_taxable"]
    effective_taxable = if(is_number(taxable), do: taxable, else: complete_lines_taxable(lines))
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
      is_number(grand) and is_number(effective_taxable),
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
      is_number(effective_taxable) and is_number(total_tax) and implied_rate(lines) != nil,
      :arithmetic,
      "tax_is_rate_times_taxable",
      close?(num(effective_taxable) * num(implied_rate(lines)) / 100, num(total_tax), 2.0),
      %{rate: implied_rate(lines), on: effective_taxable, printed: total_tax}
    )
  end

  # Under reverse charge the supplier does not collect the tax — the recipient
  # pays it to the government — so the bill's own total excludes it. Freight and
  # legal fees are routinely RCM, so an invariant that always adds tax to the
  # total does not merely misfire here, it misfires on a whole category of real
  # purchases, and a check that cries wolf on a category is a check nobody reads.
  defp computed_grand_total(data, reverse_charge?) do
    lines = data["line_items"] || []

    base =
      case {complete_lines_taxable(lines), reverse_charge? or complete_line_taxes?(lines)} do
        {taxable, true} when is_number(taxable) ->
          tax = if reverse_charge?, do: 0.0, else: sum_line_tax(lines)
          taxable + tax

        _incomplete_lines ->
          tax = if reverse_charge?, do: 0.0, else: num(data["printed_total_tax"])
          num(data["printed_total_taxable"]) + tax
      end

    base + num(data["printed_additional_charges"]) + num(data["printed_rounding_adjustment"])
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

  @credit_note ~r/(?:^|\n)[\s|#>*_-]*(?:tax\s+)?credit\s+note(?:\s*(?:no\.?|number)?\s*[:#-]?\s*[A-Z0-9][^\n]*)?\s*[*_]*(?:\||$)/im
  @debit_note ~r/(?:^|\n)[\s|#>*_-]*(?:tax\s+)?debit\s+note(?:\s*(?:no\.?|number)?\s*[:#-]?\s*[A-Z0-9][^\n]*)?\s*[*_]*(?:\||$)/im
  @export ~r/\b(export\s+invoice|letter\s+of\s+undertaking|\bLUT\b|special\s+economic\s+zone|\bSEZ\b|supply\s+meant\s+for\s+export)\b|\b(USD|EUR|GBP|AED|SGD)\s*[\d.,]/i

  @doc """
  What kind of document the page says it is, read off the page and nothing else.

  Credit/debit headings independently verify the structured document type.
  Export and outward reverse-charge markers name shapes the current return still
  cannot file, so they are detected here where the text is and refused at sign-off
  rather than coerced into an ordinary taxable invoice.

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

  Structured filing classifications are now correctable fields, but these
  page-wide markers remain independent evidence. A marker disagreement must
  therefore stay visible rather than being silently overwritten by extraction.
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

  defp sum_taxable(lines) do
    lines |> Enum.map(&LineAmounts.taxable_value/1) |> Enum.reject(&is_nil/1) |> Enum.sum()
  end

  defp complete_lines_taxable([]), do: nil

  defp complete_lines_taxable(lines) do
    values = Enum.map(lines, &LineAmounts.taxable_value/1)
    if Enum.all?(values, &is_number/1), do: Enum.sum(values)
  end

  defp complete_line_taxes?(lines) do
    Enum.all?(lines, fn line ->
      cond do
        num(line["igst_rate"]) > 0 ->
          is_number(line["igst_amount"])

        num(line["cgst_rate"]) + num(line["sgst_rate"]) > 0 ->
          is_number(line["cgst_amount"]) and is_number(line["sgst_amount"])

        true ->
          true
      end
    end)
  end

  defp sum_line_tax(lines) do
    Enum.reduce(lines, 0.0, fn line, total ->
      total + num(line["cgst_amount"]) + num(line["sgst_amount"]) + num(line["igst_amount"])
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

  defp failed_source_presence?(%{kind: :source_presence, ok?: false}), do: true

  defp failed_source_presence?(%{"kind" => kind}) when kind in ~w(source_presence grounding),
    do: true

  defp failed_source_presence?(_check), do: false

  defp check_field(%{field: field}), do: field
  defp check_field(%{"field" => field}), do: field

  defp source_numeric_field?(field) when field in @printed_money, do: true

  defp source_numeric_field?("line_items[" <> rest) do
    case Regex.run(~r/^\d+\]\.([^\]]+)$/, rest) do
      [_, field] -> field in @source_line_numbers
      _invalid -> false
    end
  end

  defp source_numeric_field?(_field), do: false

  defp field_value(data, "line_items[" <> rest) do
    case Regex.run(~r/^(\d+)\]\.(.+)$/, rest) do
      [_, index, field] ->
        get_in(data, ["line_items", Access.at(String.to_integer(index)), field])

      _invalid ->
        nil
    end
  end

  defp field_value(data, field), do: data[field]

  defp clear_field(data, "line_items[" <> rest) do
    case Regex.run(~r/^(\d+)\]\.(.+)$/, rest) do
      [_, index, field] ->
        update_in(data, ["line_items"], fn lines ->
          List.update_at(lines || [], String.to_integer(index), &Map.put(&1, field, nil))
        end)

      _invalid ->
        data
    end
  end

  defp clear_field(data, field), do: Map.put(data, field, nil)

  defp flags(data, checks, haystack) do
    absent = Enum.filter(checks, &(&1.kind == :source_presence and not &1.ok?))
    failed_arithmetic = Enum.filter(checks, &(&1.kind == :arithmetic and not &1.ok?))

    []
    |> add(absent != [], fn ->
      {:value_not_on_page, Enum.map(absent, & &1.field)}
    end)
    |> add(failed_arithmetic != [] and absent == [], fn ->
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
    lines_sum = sum_taxable(lines)
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

  defp num(value) when is_number(value), do: value / 1
  defp num(_value), do: 0.0

  defp close?(a, b, tolerance \\ @tolerance)
  defp close?(a, b, tolerance) when is_number(a) and is_number(b), do: abs(a - b) <= tolerance
  defp close?(_a, _b, _tolerance), do: false
end
