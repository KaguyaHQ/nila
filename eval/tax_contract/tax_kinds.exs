Code.require_file("eval/support/requests.exs")

defmodule Nila.Eval.TaxKinds do
  def candidate(request) do
    schema = request.schema |> Jason.encode!() |> Jason.decode!() |> transform_schema()

    messages =
      Enum.map(request.messages, fn
        %{role: "user", content: [first | rest]} = message ->
          old =
            "- For every line-level tax type or tax column, copy its printed label, rate and amount into printed_tax_components. Preserve the printed label instead of deciding which canonical GST field it belongs to. Never infer a tax head from party or delivery addresses or accounting rules."

          new =
            "- Understand each tax from the wording, headings and layout. Return its kind as cgst, sgst, igst, cess, combined or unknown. Combined means one amount covering taxes together; unknown means you cannot identify the kind. Put item taxes in printed_tax_components and invoice-summary taxes in printed_tax_totals. Do not infer a tax kind from party or delivery addresses. Return amounts and rates shown in the bill; do not calculate missing numbers."

          true = String.contains?(first.text, old)
          instruction = String.replace(first.text, old, new)

          instruction =
            Regex.replace(~r/```json\r?\n(.*?)\r?\n```/s, instruction, fn _, json ->
              "```json\n" <>
                (json |> Jason.decode!() |> transform_example() |> Jason.encode!()) <> "\n```"
            end)

          false = String.contains?(instruction, "printed_label")
          %{message | content: [%{first | text: instruction} | rest]}

        message ->
          message
      end)

    %{request | schema: schema, messages: messages}
  end

  defp transform_schema(%{"properties" => %{"printed_label" => _} = properties} = schema) do
    fields = %{
      "kind" => %{
        "type" => "string",
        "enum" => ["cgst", "sgst", "igst", "cess", "combined", "unknown"],
        "description" =>
          "Tax kind understood from the wording, headings and layout. Combined means an amount covering taxes together. Use unknown when unclear."
      },
      "amount" => %{
        "anyOf" => [%{"type" => "number"}, %{"type" => "null"}],
        "description" =>
          "Tax amount shown for this item or invoice summary; null when absent or unclear."
      }
    }

    fields =
      if Map.has_key?(properties, "printed_rate"),
        do:
          Map.put(fields, "rate", %{
            "anyOf" => [%{"type" => "number"}, %{"type" => "null"}],
            "description" => "Tax percentage shown for this item; null when absent or unclear."
          }),
        else: fields

    schema
    |> Map.put("properties", fields)
    |> Map.put("required", fields |> Map.keys() |> Enum.sort())
  end

  defp transform_schema(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      value =
        case value do
          "Tax components printed for this item. Copy each label, rate and amount as printed; return an empty list when none is printed." ->
            "Taxes shown for this item, classified by meaning. Return an empty list when none is shown."

          "Invoice-level tax totals as printed, including separate tax-head totals and a generic Tax Amount or Total Tax. Copy each printed total once; return an empty list when none is printed." ->
            "Invoice-level tax totals, classified by meaning. Include separate tax kinds or a combined tax total as the invoice shows them. Return each amount once; return an empty list when none is shown."

          other ->
            transform_schema(other)
        end

      {key, value}
    end)
  end

  defp transform_schema(list) when is_list(list), do: Enum.map(list, &transform_schema/1)
  defp transform_schema(value), do: value

  defp transform_example(%{"printed_label" => label} = component) do
    result = %{
      "kind" => if(label == "GST", do: "combined", else: String.downcase(label)),
      "amount" => component["printed_amount"]
    }

    if Map.has_key?(component, "printed_rate"),
      do: Map.put(result, "rate", component["printed_rate"]),
      else: result
  end

  defp transform_example(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, transform_example(value)} end)

  defp transform_example(list) when is_list(list), do: Enum.map(list, &transform_example/1)
  defp transform_example(value), do: value
end
