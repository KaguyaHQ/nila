defmodule Nila.Gst.Extraction.LineAmounts do
  @moduledoc false

  @bases ~w(inclusive exclusive unknown)
  @tolerance 0.02

  def normalize(line) when is_map(line) do
    printed_unit_price = money(evidence_value(line, "printed_unit_price", "unit_price"))
    printed_line_amount = money(printed_line_amount(line))
    printed_line_total = money(line["printed_line_total"])
    printed_taxable_value = money(printed_taxable_value(line))
    candidate = inclusion_candidate(line)

    resolution =
      resolve_inclusion(
        line,
        printed_line_amount,
        printed_line_total,
        candidate
      )

    {taxable_value, taxable_value_basis} =
      resolve_taxable_value(
        line,
        printed_taxable_value,
        printed_line_amount,
        resolution.inclusion,
        resolution.basis
      )

    %{
      printed_unit_price: printed_unit_price,
      printed_line_amount: printed_line_amount,
      printed_line_total: printed_line_total,
      printed_taxable_value: printed_taxable_value,
      line_amount_tax_inclusion_candidate: candidate,
      line_amount_tax_inclusion: resolution.inclusion,
      line_amount_tax_inclusion_basis: resolution.basis,
      line_amount_tax_inclusion_evidence: resolution.evidence,
      line_amount_tax_inclusion_disagreement: disagreement(candidate, resolution.inclusion),
      taxable_value: taxable_value,
      taxable_value_basis: taxable_value_basis
    }
  end

  def taxable_value(line) when is_map(line), do: normalize(line).taxable_value

  defp resolve_inclusion(
         %{
           "line_amount_tax_inclusion_basis" => "corrected",
           "line_amount_tax_inclusion" => inclusion
         },
         _amount,
         _total,
         _candidate
       )
       when inclusion in @bases do
    %{
      inclusion: inclusion,
      basis: "corrected",
      evidence: ["reviewer_correction"]
    }
  end

  defp resolve_inclusion(line, amount, total, candidate) do
    equations = arithmetic_equations(line, amount, total)
    passed = Enum.filter(equations, & &1.passed)
    failed = Enum.reject(equations, & &1.passed)

    cond do
      passed != [] and failed == [] ->
        %{
          inclusion: "exclusive",
          basis: passed |> hd() |> Map.fetch!(:basis),
          evidence: Enum.map(passed, &equation_evidence/1)
        }

      passed != [] and failed != [] ->
        %{
          inclusion: "unknown",
          basis: "arithmetic_conflict",
          evidence: Enum.map(equations, &equation_evidence/1)
        }

      candidate in ~w(inclusive exclusive) ->
        %{inclusion: candidate, basis: "model_candidate", evidence: []}

      true ->
        %{inclusion: "unknown", basis: nil, evidence: []}
    end
  end

  defp arithmetic_equations(line, amount, total) do
    tax = line_tax(line)

    []
    |> add_total_equation(amount, tax, total)
    |> add_rate_equation(line, amount, tax)
  end

  defp add_total_equation(equations, amount, tax, total)
       when is_number(amount) and is_number(tax) and is_number(total) do
    if nonzero?(tax) do
      add_equation(equations, "line_amount_plus_tax_equals_total", amount + tax, total)
    else
      equations
    end
  end

  defp add_total_equation(equations, _amount, _tax, _total), do: equations

  defp add_rate_equation(equations, line, amount, tax)
       when is_number(amount) and is_number(tax) do
    rate = rate(line)

    if rate > 0 and complete_tax_for_rate?(line) do
      add_equation(equations, "line_amount_times_rate_equals_tax", amount * rate / 100, tax)
    else
      equations
    end
  end

  defp add_rate_equation(equations, _line, _amount, _tax), do: equations

  defp add_equation(equations, basis, left, right) do
    equations ++
      [%{basis: basis, passed: close?(left, right), left: round2(left), right: round2(right)}]
  end

  defp equation_evidence(equation) do
    %{
      "basis" => equation.basis,
      "passed" => equation.passed,
      "left" => equation.left,
      "right" => equation.right
    }
  end

  defp resolve_taxable_value(
         %{"taxable_value_basis" => "corrected"} = line,
         _printed,
         _amount,
         _inclusion,
         _inclusion_basis
       ) do
    {money(line["taxable_value"]), "corrected"}
  end

  defp resolve_taxable_value(_line, printed, _amount, _inclusion, _basis)
       when is_number(printed),
       do: {printed, "printed_taxable_value"}

  defp resolve_taxable_value(line, nil, amount, "inclusive", _basis)
       when is_number(amount) do
    case amount_rate_taxable(amount, line) do
      nil -> {nil, nil}
      taxable -> {taxable, "derived_from_inclusive_line_amount"}
    end
  end

  defp resolve_taxable_value(_line, nil, amount, "exclusive", inclusion_basis)
       when is_number(amount) do
    basis =
      if inclusion_basis in ~w(line_amount_plus_tax_equals_total line_amount_times_rate_equals_tax),
        do: inclusion_basis,
        else: "printed_exclusive_line_amount"

    {amount, basis}
  end

  defp resolve_taxable_value(_line, _printed, _amount, _inclusion, _basis), do: {nil, nil}

  defp amount_rate_taxable(amount, line) do
    rate = rate(line)
    if rate > 0, do: round2(amount / (1 + rate / 100))
  end

  defp inclusion_candidate(line) do
    stored_candidate = line["line_amount_tax_inclusion_candidate"]
    current = line["line_amount_tax_inclusion"]

    cond do
      stored_candidate == "unknown" and current in ~w(inclusive exclusive) and
          is_nil(line["line_amount_tax_inclusion_basis"]) ->
        current

      stored_candidate in @bases ->
        stored_candidate

      current in @bases ->
        current

      line["tax_inclusive"] == true ->
        "inclusive"

      true ->
        "unknown"
    end
  end

  defp disagreement(candidate, resolved)
       when candidate in ~w(inclusive exclusive) and resolved in ~w(inclusive exclusive) and
              candidate != resolved,
       do: %{"candidate" => candidate, "resolved" => resolved}

  defp disagreement(_candidate, _resolved), do: nil

  defp printed_line_amount(line) do
    if Map.has_key?(line, "printed_line_amount") do
      line["printed_line_amount"]
    else
      line["tax_inclusive_value"]
    end
  end

  defp printed_taxable_value(line) do
    cond do
      Map.has_key?(line, "printed_taxable_value") -> line["printed_taxable_value"]
      line["taxable_value_basis"] in ~w(corrected derived_from_inclusive_line_amount) -> nil
      true -> line["taxable_value"]
    end
  end

  defp evidence_value(line, current, previous) do
    if Map.has_key?(line, current), do: line[current], else: line[previous]
  end

  defp line_tax(line) do
    amounts = Enum.map(~w(cgst_amount sgst_amount igst_amount), &money(line[&1]))

    case Enum.reject(amounts, &is_nil/1) do
      [] -> nil
      present -> Enum.sum(present)
    end
  end

  defp complete_tax_for_rate?(line) do
    pairs = [
      {money(line["cgst_rate"]), money(line["cgst_amount"])},
      {money(line["sgst_rate"]), money(line["sgst_amount"])},
      {money(line["igst_rate"]), money(line["igst_amount"])}
    ]

    Enum.any?(pairs, fn {rate, _amount} -> is_number(rate) and rate > 0 end) and
      Enum.all?(pairs, fn
        {rate, amount} when is_number(rate) and rate > 0 -> is_number(amount)
        _inactive -> true
      end)
  end

  defp rate(line) do
    num(line["cgst_rate"]) + num(line["sgst_rate"]) + num(line["igst_rate"])
  end

  defp money(nil), do: nil
  defp money(value) when is_number(value), do: value

  defp money(value) when is_binary(value) do
    value = String.replace(value, ~r/[^0-9.\-]/, "")

    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp money(_value), do: nil
  defp num(value), do: money(value) || 0
  defp nonzero?(value), do: abs(value) > @tolerance
  defp close?(left, right), do: abs(left - right) <= @tolerance + 0.000001
  defp round2(value), do: Float.round(value / 1, 2)
end
