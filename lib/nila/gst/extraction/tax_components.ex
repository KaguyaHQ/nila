defmodule Nila.Gst.Extraction.TaxComponents do
  @moduledoc """
  Projects source-shaped printed tax components into Nila's canonical GST heads.

  The extractor reports what the invoice prints. This module performs the small,
  deterministic translation accounting code needs, while retaining the source
  components on every line. Only printed component lists supply projected heads;
  missing lists supply no evidence. Unknown labels and duplicate heads remain
  visible as issues instead of being guessed or summed.
  """

  @canonical_fields ~w(cgst_rate cgst_amount sgst_rate sgst_amount igst_rate igst_amount)
  @heads ~w(CGST SGST IGST)

  @doc "Resolves invoice-level printed GST without changing the captured evidence."
  def printed_tax_total(data) do
    case Nila.Gst.Money.paise_or_error(data["printed_total_tax"]) do
      {:ok, paise} -> paise / 100
      :missing -> component_total(data["printed_tax_totals"])
      :unreadable -> nil
    end
  end

  defp component_total(components) when is_list(components) do
    {heads, combined, issues} = classify_invoice_totals(components)

    cond do
      match?([_], combined) ->
        sum_printed_amounts(combined)

      combined != [] or issues != [] ->
        nil

      Enum.sort(Map.keys(heads)) not in [["IGST"], ["CGST", "SGST"], ["CGST", "IGST", "SGST"]] ->
        nil

      Enum.any?(heads, fn {_head, values} -> length(values) != 1 end) ->
        nil

      true ->
        heads |> Map.values() |> List.flatten() |> sum_printed_amounts()
    end
  end

  defp component_total(_components), do: nil

  defp sum_printed_amounts(components) do
    Enum.reduce_while(components, 0, fn component, total ->
      case Nila.Gst.Money.paise_or_error(component["printed_amount"]) do
        {:ok, paise} -> {:cont, total + paise}
        _missing_or_unreadable -> {:halt, nil}
      end
    end)
    |> case do
      nil -> nil
      paise -> paise / 100
    end
  end

  @doc "Projects printed invoice totals and line components, retaining their evidence."
  def project(data) when is_map(data) do
    data
    |> project_invoice_totals()
    |> Map.update("line_items", [], fn lines -> Enum.map(lines, &project_line/1) end)
  end

  defp project_invoice_totals(data) do
    {recognized, combined, issues} = classify_invoice_totals(data["printed_tax_totals"] || [])

    {projected, duplicates} =
      Enum.reduce(@heads, {clear_invoice_totals(data), []}, fn head, {current, issues} ->
        case Map.get(recognized, head, []) do
          [component] ->
            {Map.put(current, "printed_#{String.downcase(head)}", component["printed_amount"]),
             issues}

          [] ->
            {current, issues}

          duplicates ->
            {current, issues ++ [duplicate_head(head, duplicates)]}
        end
      end)

    {projected, combined_issues} =
      case combined do
        [component] ->
          {Map.put(projected, "printed_total_tax", component["printed_amount"]), []}

        [] ->
          {projected, []}

        duplicates ->
          {projected, [%{"kind" => "duplicate_total_tax", "count" => length(duplicates)}]}
      end

    put_issues(projected, "tax_total_issues", issues ++ duplicates ++ combined_issues)
  end

  defp project_line(line) do
    {recognized, issues} = classify(line["printed_tax_components"] || [])

    {projected, duplicates} =
      Enum.reduce(@heads, {clear_canonical(line), []}, fn head, {current, issues} ->
        case Map.get(recognized, head, []) do
          [component] -> {put_component(current, head, component), issues}
          [] -> {current, issues}
          duplicates -> {current, issues ++ [duplicate_head(head, duplicates)]}
        end
      end)

    put_issues(projected, "tax_component_issues", issues ++ duplicates)
  end

  defp classify(components) do
    Enum.reduce(components, {%{}, []}, fn component, {recognized, issues} ->
      case normalized_head(component["printed_label"]) do
        head when head in @heads ->
          {Map.update(recognized, head, [component], &[component | &1]), issues}

        _unknown ->
          issue = %{
            "kind" => "unknown_tax_label",
            "printed_label" => component["printed_label"]
          }

          {recognized, issues ++ [issue]}
      end
    end)
  end

  defp classify_invoice_totals(components) do
    Enum.reduce(components, {%{}, [], []}, fn component, {recognized, combined, issues} ->
      case invoice_total_kind(component["printed_label"]) do
        {:head, head} ->
          {Map.update(recognized, head, [component], &[component | &1]), combined, issues}

        :combined ->
          {recognized, [component | combined], issues}

        :unknown ->
          issue = %{
            "kind" => "unknown_tax_label",
            "printed_label" => component["printed_label"]
          }

          {recognized, combined, issues ++ [issue]}
      end
    end)
  end

  defp invoice_total_kind(label) when is_binary(label) do
    tokens = label_tokens(label)
    heads = tokens |> Enum.filter(&(&1 in @heads)) |> Enum.uniq()

    cond do
      length(heads) > 1 -> :combined
      match?([_head], heads) -> {:head, hd(heads)}
      "TAX" in tokens and Enum.any?(["TOTAL", "AMOUNT"], &(&1 in tokens)) -> :combined
      true -> :unknown
    end
  end

  defp invoice_total_kind(_label), do: :unknown

  defp normalized_head(label) when is_binary(label) do
    compact =
      label
      |> String.upcase()
      |> String.replace(~r/[^A-Z]/u, "")

    heads =
      label
      |> label_tokens()
      |> Enum.filter(&(&1 in @heads))
      |> Enum.uniq()

    cond do
      compact in @heads -> compact
      match?([_head], heads) -> hd(heads)
      true -> nil
    end
  end

  defp normalized_head(_label), do: nil

  defp label_tokens(label) do
    label
    |> String.upcase()
    |> String.split(~r/[^A-Z]+/u, trim: true)
  end

  defp clear_canonical(line) do
    Enum.reduce(@canonical_fields, line, &Map.put(&2, &1, nil))
  end

  defp clear_invoice_totals(data) do
    Enum.reduce(@heads, Map.put(data, "printed_total_tax", nil), fn head, current ->
      Map.put(current, "printed_#{String.downcase(head)}", nil)
    end)
  end

  defp put_component(line, head, component) do
    prefix = String.downcase(head)

    line
    |> Map.put("#{prefix}_rate", component["printed_rate"])
    |> Map.put("#{prefix}_amount", component["printed_amount"])
  end

  defp duplicate_head(head, components) do
    %{"kind" => "duplicate_tax_head", "head" => head, "count" => length(components)}
  end

  # Issues describe the current evidence, not earlier projections of this map.
  defp put_issues(data, field, []), do: Map.delete(data, field)
  defp put_issues(data, field, issues), do: Map.put(data, field, issues)
end
