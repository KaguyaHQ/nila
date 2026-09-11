defmodule Nila.Gst.LineAmounts do
  @moduledoc """
  Resolves one item's taxable value while keeping its printed amounts separate.

  For two units at ₹50 before 18% GST, the printed unit price is ₹50, the
  line amount may be ₹100, the final line total ₹118, and a separate taxable
  column ₹100. A line amount can also include GST; its name alone proves nothing.

  Accepts string-keyed extracted or previously reviewed lines and returns an
  atom-keyed result. Reviewer corrections take priority. Otherwise, use a printed
  taxable value before deriving one from the line amount. Arithmetic can prove
  exclusive pricing. If one available check passes and another fails, inclusion
  is unknown. If no check passes, retain the model candidate and the failed checks.

  When the pre-tax item amount is absent, a printed gross total minus complete
  item GST can supply taxable value. Printed rates must agree with that result;
  footer taxes and unresolved or duplicate item components cannot supply it.

  Only the current printed fields supply evidence. Missing fields stay missing;
  a previously calculated taxable value is used only when marked as corrected.
  """

  alias Nila.Gst.Money

  @arithmetic_bases ~w(line_amount_plus_tax_equals_total line_amount_times_rate_equals_tax)
  @inclusions ~w(inclusive exclusive unknown)
  @tolerance 0.02

  def normalize(line) when is_map(line) do
    facts = read_line(line)
    inclusion = resolve_inclusion(facts)
    {taxable_value, taxable_value_basis} = resolve_taxable_value(facts, inclusion)

    %{
      printed_unit_price: facts.unit_price,
      printed_line_amount: facts.amount,
      printed_line_total: facts.total,
      printed_taxable_value: facts.printed_taxable,
      line_amount_tax_inclusion_candidate: facts.candidate,
      line_amount_tax_inclusion: inclusion.value,
      line_amount_tax_inclusion_basis: inclusion.basis,
      line_amount_tax_inclusion_evidence: inclusion.evidence,
      line_amount_tax_inclusion_disagreement: disagreement(facts.candidate, inclusion.value),
      taxable_value: taxable_value,
      taxable_value_basis: taxable_value_basis
    }
  end

  def taxable_value(line) when is_map(line), do: normalize(line).taxable_value

  # Decision order: reviewer, arithmetic proof/conflict, model, unknown.
  defp resolve_inclusion(facts) do
    checks = Enum.reject([total_check(facts), rate_check(facts)], &is_nil/1)
    {passed, failed} = Enum.split_with(checks, & &1["passed"])

    cond do
      facts.inclusion_corrected? ->
        %{value: facts.corrected_inclusion, basis: "corrected", evidence: ["reviewer_correction"]}

      passed != [] and failed == [] ->
        %{value: "exclusive", basis: hd(passed)["basis"], evidence: checks}

      passed != [] and failed != [] ->
        %{value: "unknown", basis: "arithmetic_conflict", evidence: checks}

      facts.candidate in ~w(inclusive exclusive) ->
        # These checks test exclusive pricing only. Failure does not rule out
        # an inclusive candidate, but the failed arithmetic is still evidence.
        %{value: facts.candidate, basis: "model_candidate", evidence: checks}

      true ->
        %{value: "unknown", basis: nil, evidence: checks}
    end
  end

  defp resolve_taxable_value(facts, inclusion) do
    cond do
      facts.taxable_corrected? ->
        {facts.corrected_taxable, "corrected"}

      is_number(facts.printed_taxable) ->
        {facts.printed_taxable, "printed_taxable_value"}

      not is_number(facts.amount) ->
        if facts.amount_missing? and facts.printed_taxable_missing?,
          do: derive_from_gross(facts),
          else: {nil, nil}

      inclusion.value == "exclusive" ->
        basis =
          if inclusion.basis in @arithmetic_bases,
            do: inclusion.basis,
            else: "printed_exclusive_line_amount"

        {facts.amount, basis}

      inclusion.value == "inclusive" and facts.rate > 0 ->
        {round2(facts.amount / (1 + facts.rate / 100)), "derived_from_inclusive_line_amount"}

      true ->
        {nil, nil}
    end
  end

  # The gross column already states its meaning. It does not need a separate
  # pre-tax amount or an inclusion guess, but it does need complete item taxes.
  defp derive_from_gross(%{total: total, gross_taxes: taxes})
       when is_number(total) and is_list(taxes) and total >= 0 do
    tax = Enum.sum(Enum.map(taxes, &elem(&1, 2)))
    taxable = total - tax

    consistent? =
      Enum.all?(taxes, fn {_head, rate, amount} ->
        is_nil(rate) or (is_number(rate) and rate >= 0 and close?(taxable * rate / 100, amount))
      end)

    if taxable >= 0 and consistent?,
      do: {round2(taxable), "derived_from_gross_less_printed_tax"},
      else: {nil, nil}
  end

  defp derive_from_gross(_facts), do: {nil, nil}

  defp total_check(%{amount: amount, tax: tax, total: total}) do
    if is_number(amount) and is_number(tax) and is_number(total) and nonzero?(tax) do
      check("line_amount_plus_tax_equals_total", amount + tax, total)
    end
  end

  defp rate_check(%{amount: amount, tax: tax, rate: rate} = facts) do
    if is_number(amount) and is_number(tax) and nonzero?(tax) and rate > 0 and
         facts.complete_tax? do
      check("line_amount_times_rate_equals_tax", amount * rate / 100, tax)
    end
  end

  defp check(basis, left, right) do
    %{
      "basis" => basis,
      "passed" => close?(left, right),
      "left" => round2(left),
      "right" => round2(right)
    }
  end

  # Read printed numbers and review markers once, before making decisions.
  defp read_line(line) do
    taxes =
      Enum.map(~w(cgst sgst igst), fn head ->
        {money(line[head <> "_rate"]), money(line[head <> "_amount"])}
      end)

    tax_amounts = taxes |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)
    active_taxes = Enum.filter(taxes, fn {rate, _amount} -> is_number(rate) and rate > 0 end)

    %{
      unit_price: money(line["printed_unit_price"]),
      amount: money(line["printed_line_amount"]),
      amount_missing?: Money.decimal_or_error(line["printed_line_amount"]) == :missing,
      total: money(line["printed_line_total"]),
      printed_taxable: money(line["printed_taxable_value"]),
      printed_taxable_missing?: Money.decimal_or_error(line["printed_taxable_value"]) == :missing,
      gross_taxes: gross_taxes(line),
      candidate: inclusion_candidate(line),
      inclusion_corrected?:
        line["line_amount_tax_inclusion_basis"] == "corrected" and
          line["line_amount_tax_inclusion"] in @inclusions,
      corrected_inclusion: line["line_amount_tax_inclusion"],
      taxable_corrected?: line["taxable_value_basis"] == "corrected",
      corrected_taxable: money(line["taxable_value"]),
      rate: Enum.sum(Enum.map(taxes, fn {rate, _amount} -> rate || 0 end)),
      tax: if(tax_amounts == [], do: nil, else: Enum.sum(tax_amounts)),
      complete_tax?:
        active_taxes != [] and
          Enum.all?(active_taxes, fn {_rate, amount} -> is_number(amount) end)
    }
  end

  defp gross_taxes(line) do
    canonical =
      ~w(CGST SGST IGST)
      |> Enum.map(fn head ->
        prefix = String.downcase(head)
        {head, tax_number(line[prefix <> "_rate"]), tax_number(line[prefix <> "_amount"])}
      end)
      |> Enum.filter(fn {_head, rate, amount} ->
        rate not in [nil, 0, 0.0] or amount not in [nil, 0, 0.0]
      end)

    case line["printed_tax_components"] do
      nil ->
        complete_gross_taxes(canonical)

      components when is_list(components) ->
        printed =
          Enum.map(components, fn component ->
            {gross_tax_head(component["printed_label"]), tax_number(component["printed_rate"]),
             money(component["printed_amount"])}
          end)

        # Projected heads are another view of the same evidence, never extra tax.
        # If they disagree, leave the amount unresolved for review.
        if canonical == [] or canonical_matches?(printed, canonical),
          do: complete_gross_taxes(printed)

      _unreadable ->
        nil
    end
  end

  defp complete_gross_taxes(taxes) do
    heads = taxes |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    if heads in [["GST"], ["IGST"], ["CGST", "SGST"]] and
         Enum.all?(taxes, fn {_head, _rate, amount} -> is_number(amount) and amount >= 0 end),
       do: taxes
  end

  defp canonical_matches?(printed, canonical) do
    Enum.all?(canonical, fn {head, rate, amount} ->
      case Enum.filter(printed, &(elem(&1, 0) == head)) do
        [{^head, printed_rate, printed_amount}] ->
          is_number(amount) and is_number(printed_amount) and close?(amount, printed_amount) and
            (is_nil(rate) or is_nil(printed_rate) or
               (is_number(rate) and is_number(printed_rate) and close?(rate, printed_rate)))

        _missing_or_duplicate ->
          false
      end
    end)
  end

  defp gross_tax_head(label) when is_binary(label) do
    case label |> String.upcase() |> String.split(~r/[^A-Z]+/u, trim: true) do
      [head] when head in ~w(GST CGST SGST IGST) -> head
      _unknown -> nil
    end
  end

  defp gross_tax_head(_label), do: nil

  defp tax_number(value) do
    case Money.decimal_or_error(value) do
      :missing -> nil
      :unreadable -> :unreadable
      {:ok, _decimal} -> money(value)
    end
  end

  defp inclusion_candidate(line) do
    # Extraction supplies the initial inclusion. Once normalized, preserve that
    # candidate even if arithmetic or a reviewer changes the resolved inclusion.
    stored_candidate = line["line_amount_tax_inclusion_candidate"]
    current = line["line_amount_tax_inclusion"]

    cond do
      stored_candidate in @inclusions ->
        stored_candidate

      current in @inclusions ->
        current

      true ->
        "unknown"
    end
  end

  defp disagreement(candidate, resolved)
       when candidate in ~w(inclusive exclusive) and resolved in ~w(inclusive exclusive) and
              candidate != resolved,
       do: %{"candidate" => candidate, "resolved" => resolved}

  defp disagreement(_candidate, _resolved), do: nil

  defp money(value), do: Money.rupee_number(value)
  defp nonzero?(value), do: abs(value) > @tolerance
  defp close?(left, right), do: abs(left - right) <= @tolerance + 0.000001
  defp round2(value), do: Float.round(value / 1, 2)
end
