defmodule Nila.Gst.Sales.InvoiceTaxes do
  @moduledoc """
  Keeps printed invoice taxes available and resolves supported item splits.

  A footer rate or a matching combined item GST component can establish a split.
  A sole item can take the invoice taxes when its base reconciles. Multiple items
  never acquire a uniform rate merely from the invoice's average tax rate.
  """

  alias Nila.Gst.Money
  @heads ~w(cgst sgst igst)
  @fields for head <- @heads, suffix <- ~w(rate amount), do: "#{head}_#{suffix}"

  def reset(invoice) do
    Map.update(invoice, "line_items", [], fn lines ->
      Enum.map(lines, fn line ->
        case Map.pop(line, "invoice_tax_derivation") do
          {nil, line} ->
            line

          {%{"values" => values, "original" => original}, line} ->
            Enum.reduce(values, line, fn {field, value}, restored ->
              if restored[field] == value,
                do: Map.put(restored, field, original[field]),
                else: restored
            end)
        end
      end)
    end)
  end

  def resolve(invoice) do
    lines = invoice["line_items"] || []

    with {:ok, footer} <- footer(invoice),
         true <- lines != [] and allocation_scope?(invoice, lines, footer),
         {:ok, resolved} <- resolve_lines(lines, footer),
         true <- reconciles?(resolved, footer) do
      Map.put(invoice, "line_items", resolved)
    else
      _ -> invoice
    end
  end

  @doc "Invoice tax heads prefer the printed footer; absent item heads are not a substitute for it."
  def printed_totals(invoice) do
    case footer(invoice) do
      {:ok, heads} -> Map.new(heads, fn {head, fact} -> {head, fact.amount / 100} end)
      _ -> %{}
    end
  end

  def totals(invoice) do
    printed =
      case footer(invoice) do
        {:ok, heads} -> heads
        _ -> %{}
      end

    Map.new(@heads, fn head ->
      amount =
        case printed[head] do
          %{amount: amount} ->
            amount / 100

          nil ->
            values = Enum.map(invoice["line_items"] || [], & &1[head <> "_amount"])

            if Enum.any?(values, &is_number/1),
              do: Enum.sum(Enum.filter(values, &is_number/1)),
              else: 0
        end

      {head, amount}
    end)
  end

  @doc "Positive footer tax needs review when the item amounts cannot account for it."
  def unresolved?(invoice) do
    case footer(invoice) do
      {:ok, heads} ->
        Enum.any?(heads, fn {head, %{amount: amount}} ->
          amount > 0 and
            (invoice["line_items"] == [] or
               Enum.any?(invoice["line_items"] || [], fn line ->
                 not is_number(line[head <> "_amount"]) or
                   not is_number(line[head <> "_rate"])
               end))
        end)

      _ ->
        false
    end
  end

  defp footer(invoice) do
    components = invoice["printed_tax_totals"] || []

    Enum.reduce_while(components, {:ok, %{}}, fn component, {:ok, heads} ->
      case head(component["printed_label"]) do
        nil ->
          {:cont, {:ok, heads}}

        name ->
          case Money.paise_or_error(component["printed_amount"]) do
            {:ok, amount} when amount >= 0 ->
              if Map.has_key?(heads, name),
                do: {:halt, :ambiguous},
                else:
                  {:cont,
                   {:ok, Map.put(heads, name, %{amount: amount, rate: printed_rate(component)})}}

            _ ->
              {:halt, :ambiguous}
          end
      end
    end)
    |> case do
      {:ok, heads} when map_size(heads) > 0 -> {:ok, heads}
      _ -> :unknown
    end
  end

  defp head(label) when is_binary(label) do
    case Regex.scan(~r/CGST|SGST|IGST/i, label)
         |> List.flatten()
         |> Enum.map(&String.downcase/1)
         |> Enum.uniq() do
      [head] -> head
      _ -> nil
    end
  end

  defp head(_), do: nil

  defp printed_rate(component) do
    case component["printed_rate"] do
      rate when is_number(rate) ->
        rate

      _ ->
        case Regex.scan(~r/(\d+(?:\.\d+)?)\s*%/, component["printed_label"] || "") do
          [[_, rate]] -> rate |> Decimal.new() |> Decimal.to_float()
          _ -> nil
        end
    end
  end

  defp allocation_scope?(invoice, lines, footer) do
    bases = Enum.map(lines, &paise(&1["taxable_value"]))
    known? = Enum.all?(bases, &(is_integer(&1) and &1 >= 0))
    base = if known?, do: Enum.sum(bases), else: 0
    tax = Enum.sum(Enum.map(footer, fn {_, value} -> value.amount end))
    heads = Enum.sort(Map.keys(footer))

    no_adjustments? =
      Enum.all?(
        ~w(printed_discount_amount printed_additional_charges),
        &(invoice[&1] in [nil, 0, 0.0])
      )

    summaries_match? =
      Enum.all?(~w(printed_total_taxable printed_subtotal_before_discount), fn field ->
        invoice[field] == nil or paise(invoice[field]) == base
      end)

    total = paise(invoice["printed_grand_total"])
    rounding = paise(invoice["printed_rounding_adjustment"]) || 0

    total_matches? =
      total == nil or invoice["reverse_charge"] == true or
        invoice["tax_payment"] == "without_payment" or abs(total - base - tax - rounding) <= 2

    known? and base > 0 and no_adjustments? and summaries_match? and total_matches? and
      heads in [["cgst", "sgst"], ["igst"]] and
      (heads == ["igst"] or footer["cgst"].amount == footer["sgst"].amount)
  end

  defp resolve_lines(lines, footer) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case resolve_line(line, footer, length(lines) == 1) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        _ -> {:halt, :unknown}
      end
    end)
  end

  defp resolve_line(line, footer, sole?) do
    original = Map.new(@fields, &{&1, line[&1]})

    incompatible? =
      Enum.any?(@heads, fn head ->
        not Map.has_key?(footer, head) and
          Enum.any?(
            [line[head <> "_rate"], line[head <> "_amount"]],
            &(is_number(&1) and &1 != 0)
          )
      end)

    result =
      Enum.reduce_while(footer, {:ok, line}, fn {head, fact}, {:ok, current} ->
        rate =
          line[head <> "_rate"] || combined_rate(line, head, footer) || fact.rate ||
            if(sole?, do: implied_rate(fact.amount, paise(line["taxable_value"])))

        amount = if sole?, do: fact.amount, else: tax_paise(line["taxable_value"], rate)

        if is_number(rate) and rate >= 0 and is_integer(amount) and
             tax_paise(line["taxable_value"], rate) == amount and
             (line[head <> "_amount"] == nil or paise(line[head <> "_amount"]) == amount) do
          {:cont,
           {:ok,
            current |> Map.put(head <> "_rate", rate) |> Map.put(head <> "_amount", amount / 100)}}
        else
          {:halt, :unknown}
        end
      end)

    case result do
      {:ok, resolved} when not incompatible? ->
        changed =
          Map.take(resolved, @fields)
          |> Enum.reject(fn {key, value} -> original[key] == value end)
          |> Map.new()

        if map_size(changed) == 0,
          do: {:ok, line},
          else:
            {:ok,
             Map.put(resolved, "invoice_tax_derivation", %{
               "original" => Map.take(original, Map.keys(changed)),
               "values" => changed
             })}

      _ ->
        :unknown
    end
  end

  defp combined_rate(line, head, footer) do
    case line["printed_tax_components"] || [] do
      [%{"printed_label" => label, "printed_rate" => rate, "printed_amount" => amount}]
      when is_number(rate) ->
        if String.replace(String.upcase(label || ""), ~r/[^A-Z]/, "") == "GST" and
             tax_paise(line["taxable_value"], rate) == paise(amount),
           do: if(head == "igst" and map_size(footer) == 1, do: rate, else: rate / 2)

      _ ->
        nil
    end
  end

  defp reconciles?(lines, footer) do
    Enum.all?(footer, fn {head, fact} ->
      Enum.sum(Enum.map(lines, &paise(&1[head <> "_amount"]))) == fact.amount
    end)
  end

  defp implied_rate(amount, base) when is_integer(base) and base > 0,
    do: Decimal.div(Decimal.new(amount * 100), Decimal.new(base)) |> Decimal.to_float()

  defp implied_rate(_, _), do: nil

  defp tax_paise(base, rate) when is_number(base) and is_number(rate) do
    Decimal.mult(Decimal.new(to_string(base)), Decimal.new(to_string(rate)))
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp tax_paise(_, _), do: nil

  defp paise(value) do
    case Money.paise_or_error(value) do
      {:ok, amount} -> amount
      _ -> nil
    end
  end
end
