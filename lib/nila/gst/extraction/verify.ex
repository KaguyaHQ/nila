defmodule Nila.Gst.Extraction.Verify do
  @moduledoc """
  Checks extracted invoice numbers and GSTINs without changing the invoice.

  `structured/2` checks arithmetic and GSTINs. It reports failures, but cannot
  declare source verification without an independent page transcription.
  `invoice/3` also checks that captured values occur in that transcription;
  numeric presence does not establish a number's role or location on the page.

  Arithmetic compares known totals only. Complete line amounts take precedence
  when computing a grand total; otherwise use printed invoice totals. A single
  rate applies to the whole taxable value only when every line has that rate.
  Checks retain their operands, and flags summarize failures for review.
  """

  alias Nila.Gst.Extraction.{LineAmounts, TaxComponents}
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
      [{"invoice_number", data["invoice_number"]} | party_identifiers(data)]
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
      Regex.match?(~r/(?<![0-9.])#{Regex.escape(variant)}(?![0-9]|\.[0-9])/, haystack)
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
    line_taxable = complete_lines_taxable(lines)
    printed_taxable = data["printed_total_taxable"]
    taxable = if is_number(printed_taxable), do: printed_taxable, else: line_taxable
    cgst = data["printed_cgst"]
    sgst = data["printed_sgst"]
    igst = data["printed_igst"]
    total_tax = data["printed_total_tax"]
    rate = implied_rate(lines)
    grand = computed_grand_total(data, lines, line_taxable, reverse_charge?)

    [
      arithmetic_check("lines_sum_vs_printed_taxable", line_taxable, printed_taxable, %{
        lines_sum: line_taxable,
        printed: printed_taxable
      }),
      arithmetic_check(
        "cgst_equals_sgst",
        cgst,
        sgst,
        %{cgst: cgst, sgst: sgst},
        @tight_tolerance
      ),
      arithmetic_check("tax_components_sum", printed_head_sum([cgst, sgst, igst]), total_tax, %{
        components: printed_head_sum([cgst, sgst, igst]),
        printed: total_tax
      }),
      arithmetic_check("grand_total", grand, data["printed_grand_total"], %{
        computed: grand,
        printed: data["printed_grand_total"],
        reverse_charge: reverse_charge?
      }),
      arithmetic_check(
        "tax_is_rate_times_taxable",
        if(is_number(taxable) and is_number(rate), do: taxable * rate / 100),
        total_tax,
        %{rate: rate, on: taxable, printed: total_tax},
        2.0
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Compare only known operands. Missing evidence is not a zero or a failed sum.
  defp arithmetic_check(field, left, right, detail, tolerance \\ @tolerance) do
    if is_number(left) and is_number(right) do
      check(:arithmetic, field, close?(left, right, tolerance), detail)
    end
  end

  defp printed_head_sum(heads) do
    if Enum.any?(heads, &is_number/1), do: heads |> Enum.map(&num/1) |> Enum.sum()
  end

  # Prefer complete row arithmetic. Otherwise use a known taxable total and
  # invoice tax. Reverse-charge supplies exclude tax from the bill's total.
  defp computed_grand_total(data, lines, line_taxable, reverse_charge?) do
    {taxable, tax} =
      if is_number(line_taxable) and (reverse_charge? or complete_line_taxes?(lines)) do
        {line_taxable, if(reverse_charge?, do: 0.0, else: sum_line_tax(lines))}
      else
        taxable =
          if is_number(data["printed_total_taxable"]),
            do: data["printed_total_taxable"],
            else: line_taxable

        tax = if reverse_charge?, do: 0.0, else: TaxComponents.printed_tax_total(data)
        {taxable, tax}
      end

    if is_number(taxable) and is_number(tax) do
      taxable + tax + num(data["printed_additional_charges"]) +
        num(data["printed_rounding_adjustment"])
    end
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
  Reads document markers from text independently of structured extraction.

  Credit/debit patterns look for headings; export and reverse-charge patterns
  scan the page. These are evidence for downstream classification, not filing
  decisions, and can disagree with the extracted document type.
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
    party_identifiers(data)
    |> Enum.reject(fn {_field, value} -> is_nil(value) or value == "" end)
    |> Enum.map(fn {field, value} ->
      check(:gstin, field, Gstin.valid?(value), %{value: value})
    end)
  end

  defp party_identifiers(%{"supplier" => supplier, "bill_to" => bill_to}) do
    [
      {"supplier.gstin", get_in(supplier, ["gstin"])},
      {"bill_to.gstin", get_in(bill_to, ["gstin"])}
    ]
  end

  defp party_identifiers(data) do
    [
      {"seller.gstin", get_in(data, ["seller", "gstin"])},
      {"buyer.gstin", get_in(data, ["buyer", "gstin"])}
    ]
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
          # At least one explicit zero rate distinguishes zero tax from missing rates.
          Enum.any?(~w(cgst_rate sgst_rate igst_rate), &is_number(line[&1]))
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
      Enum.map(lines, fn line ->
        heads = Enum.map(~w(cgst_rate sgst_rate igst_rate), &line[&1])
        if Enum.any?(heads, &is_number/1), do: heads |> Enum.map(&num/1) |> Enum.sum()
      end)

    case Enum.uniq(rates) do
      [rate] when is_number(rate) and rate > 0 -> rate
      _mixed_missing_or_zero -> nil
    end
  end

  # ---- flags ----

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
    |> Enum.concat(tax_component_flags(data))
  end

  defp tax_component_flags(data) do
    line_issues =
      data
      |> Map.get("line_items", [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, index} ->
        Enum.map(line["tax_component_issues"] || [], &Map.put(&1, "line", index))
      end)

    issues = (data["tax_total_issues"] || []) ++ line_issues

    if issues == [], do: [], else: [{:tax_component_issue, issues}]
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
    lines_sum = complete_lines_taxable(lines)
    total_tax = data["printed_total_tax"]
    grand = data["printed_grand_total"]
    rate = implied_rate(lines)

    [
      {"line_items", if(is_number(lines_sum) and lines_sum > 0, do: lines_sum)},
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
      Enum.any?(flags, &match?({:tax_component_issue, _}, &1)) -> :flagged
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

  defp add(flags, false, _build), do: flags
  defp add(flags, true, build), do: flags ++ [build.()]

  defp num(value) when is_number(value), do: value / 1
  defp num(_value), do: 0.0

  defp close?(a, b, tolerance \\ @tolerance)
  defp close?(a, b, tolerance) when is_number(a) and is_number(b), do: abs(a - b) <= tolerance
  defp close?(_a, _b, _tolerance), do: false
end
