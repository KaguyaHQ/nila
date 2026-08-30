defmodule Nila.Gst.Extraction.TaxComponents do
  @moduledoc """
  Projects source-shaped printed tax components into Nila's canonical GST heads.

  The extractor reports what the invoice prints. This module performs the small,
  deterministic translation accounting code needs, while retaining the source
  components on every line. Legacy artifacts that predate printed components are
  left unchanged.
  """

  @canonical_fields ~w(cgst_rate cgst_amount sgst_rate sgst_amount igst_rate igst_amount)
  @heads ~w(CGST SGST IGST)

  @doc "Projects every line that carries `printed_tax_components`."
  def project(data) when is_map(data) do
    data
    |> project_invoice_totals()
    |> Map.update("line_items", [], fn lines -> Enum.map(lines, &project_line/1) end)
  end

  defp project_invoice_totals(%{"printed_tax_totals" => components} = data)
       when is_list(components) do
    {recognized, combined, issues} = classify_invoice_totals(components)

    projected =
      Enum.reduce(@heads, clear_invoice_totals(data), fn head, current ->
        case Map.get(recognized, head, []) do
          [component] ->
            Map.put(current, "printed_#{String.downcase(head)}", component["printed_amount"])

          [] ->
            current

          duplicates ->
            add_total_duplicate_issue(current, head, length(duplicates))
        end
      end)

    projected =
      case combined do
        [component] -> Map.put(projected, "printed_total_tax", component["printed_amount"])
        [] -> projected
        duplicates -> add_combined_total_duplicate_issue(projected, length(duplicates))
      end

    issues = issues ++ Map.get(projected, "tax_total_issues", [])
    projected = Map.delete(projected, "tax_total_issues")

    if issues == [],
      do: projected,
      else: Map.put(projected, "tax_total_issues", issues)
  end

  defp project_invoice_totals(data), do: data

  defp project_line(%{"printed_tax_components" => components} = line)
       when is_list(components) do
    {recognized, issues} = classify(components)

    projected =
      Enum.reduce(@heads, clear_canonical(line), fn head, current ->
        case Map.get(recognized, head, []) do
          [component] -> put_component(current, head, component)
          [] -> current
          duplicates -> add_duplicate_issue(current, head, length(duplicates))
        end
      end)

    issues = issues ++ Map.get(projected, "tax_component_issues", [])
    projected = Map.delete(projected, "tax_component_issues")

    if issues == [],
      do: projected,
      else: Map.put(projected, "tax_component_issues", issues)
  end

  defp project_line(line), do: line

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

  defp add_duplicate_issue(line, head, count) do
    issue = %{"kind" => "duplicate_tax_head", "head" => head, "count" => count}
    Map.update(line, "tax_component_issues", [issue], &(&1 ++ [issue]))
  end

  defp add_total_duplicate_issue(data, head, count) do
    issue = %{"kind" => "duplicate_tax_head", "head" => head, "count" => count}
    Map.update(data, "tax_total_issues", [issue], &(&1 ++ [issue]))
  end

  defp add_combined_total_duplicate_issue(data, count) do
    issue = %{"kind" => "duplicate_total_tax", "count" => count}
    Map.update(data, "tax_total_issues", [issue], &(&1 ++ [issue]))
  end
end
