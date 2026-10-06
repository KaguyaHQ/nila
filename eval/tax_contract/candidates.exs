Code.require_file("eval/tax_contract/tax_kinds.exs")

defmodule Nila.Eval.TaxCandidates do
  def build(request, "production"), do: request

  def build(request, "printed-example") do
    example =
      "\nTax-location example: An item prints GST 180 (18%); the footer separately prints CGST 90 (9%) and SGST 90 (9%). The item's printed_tax_components has one entry: {\"printed_label\":\"GST\",\"printed_amount\":180,\"printed_rate\":18}. The invoice's printed_tax_totals has two entries: [{\"printed_label\":\"CGST\",\"printed_amount\":90,\"printed_rate\":9},{\"printed_label\":\"SGST\",\"printed_amount\":90,\"printed_rate\":9}]. Do not copy the item GST amount into both heads.\n"

    %{request | messages: edit_text(request.messages, &(&1 <> example))}
  end

  def build(request, "footer-rate"), do: rate_only(request)
  def build(request, "scoped-kind"), do: semantic(request)
  def build(request, "observed-kind"), do: rename_kind(semantic(request))
  def build(request, "mixed-example"), do: mixed_example(semantic(request))
  def build(request, "single-rule"), do: single_rule(semantic(request))

  def rate_only(request) do
    schema = request.schema |> Jason.encode!() |> Jason.decode!() |> update_summary()
    %{request | schema: schema}
  end

  def semantic(request) do
    request = request |> rate_only() |> Nila.Eval.TaxKinds.candidate()
    schema = scopes(request.schema)

    messages =
      Enum.map(request.messages, fn
        %{role: "user", content: [first | rest]} = message ->
          rule =
            "\nTax entry boundary: Each tax object represents one entry shown in its parent item or invoice summary. Interpret its kind using the wording and headings that apply to that entry. Preserve printed amounts and rates. A generic item GST amount remains one combined entry even when the footer separately shows CGST and SGST. Do not split an entry, borrow amounts or tax heads from another region, or calculate missing values. Use unknown when the entry's kind is unclear.\n"

          %{message | content: [%{first | text: first.text <> rule} | rest]}

        message ->
          message
      end)

    %{request | schema: schema, messages: messages}
  end

  defp update_summary(map) when is_map(map) do
    Map.new(map, fn
      {"printed_tax_totals", value} ->
        rate = %{
          "anyOf" => [%{"type" => "number"}, %{"type" => "null"}],
          "description" =>
            "Tax percentage printed for this invoice-summary tax entry, including an applicable heading; null when absent or unclear. Do not calculate it."
        }

        value = value |> put_in(["items", "properties", "printed_rate"], rate)
        value = update_in(value, ["items", "required"], &Enum.uniq(&1 ++ ["printed_rate"]))
        {"printed_tax_totals", value}

      {key, value} ->
        {key, update_summary(value)}
    end)
  end

  defp update_summary(list) when is_list(list), do: Enum.map(list, &update_summary/1)
  defp update_summary(value), do: value

  defp scopes(%{"properties" => %{"kind" => _} = properties} = map) do
    properties =
      properties
      |> put_in(
        ["kind", "description"],
        "Classify this single tax entry shown for this item, using wording and headings that apply to it. Combined means one entry covering taxes together. Do not construct underlying tax heads or borrow footer heads. Use unknown when unclear."
      )
      |> put_in(
        ["amount", "description"],
        "Amount printed for this tax entry in this item; null when absent or unclear. Do not calculate, split, duplicate, or borrow another entry's amount."
      )

    Map.put(map, "properties", properties)
  end

  defp scopes(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when key in ["printed_tax_components", "printed_tax_totals"] ->
        scope = if key == "printed_tax_components", do: "this item", else: "the invoice summary"

        value =
          put_in(
            value,
            ["items", "properties", "kind", "description"],
            "Classify this single tax entry shown in #{scope}, using wording and headings that apply to it. Combined means one entry covering taxes together. Do not construct underlying tax heads or borrow heads from another region. Use unknown when unclear."
          )

        value =
          put_in(
            value,
            ["items", "properties", "amount", "description"],
            "Amount printed for this tax entry in #{scope}; null when absent or unclear. Do not calculate, split, duplicate, or borrow another entry's amount."
          )

        value =
          put_in(
            value,
            ["items", "properties", "rate", "description"],
            "Percentage printed for this tax entry in #{scope}, including an applicable heading; null when absent or unclear. Do not calculate it."
          )

        value =
          Map.put(
            value,
            "description",
            "One object per tax entry shown in #{scope}. Preserve combined entries as combined. Return an empty list when no tax entries are shown here."
          )

        {key, value}

      {key, value} ->
        {key, scopes(value)}
    end)
  end

  defp scopes(list) when is_list(list), do: Enum.map(list, &scopes/1)
  defp scopes(value), do: value

  defp rename_kind(request) do
    # Change only the tax kind field name, including corresponding examples.
    schema =
      request.schema
      |> Jason.encode!()
      |> String.replace("\"kind\"", "\"observed_kind\"")
      |> Jason.decode!()

    messages = edit_text(request.messages, &String.replace(&1, ~r/\bkind\b/, "observed_kind"))
    %{request | schema: schema, messages: messages}
  end

  defp mixed_example(request) do
    example =
      "\nTax-location example: An item prints GST 180 (18%); the footer separately prints CGST 90 (9%) and SGST 90 (9%). The item has one tax entry: {\"kind\":\"combined\",\"amount\":180,\"rate\":18}. The summary has two entries: [{\"kind\":\"cgst\",\"amount\":90,\"rate\":9},{\"kind\":\"sgst\",\"amount\":90,\"rate\":9}]. Do not copy the item GST amount into both heads.\n"

    %{request | messages: edit_text(request.messages, &(&1 <> example))}
  end

  defp single_rule(request) do
    generic =
      "- Understand each tax from the wording, headings and layout. Return its kind as cgst, sgst, igst, cess, combined or unknown. Combined means one amount covering taxes together; unknown means you cannot identify the kind. Put item taxes in printed_tax_components and invoice-summary taxes in printed_tax_totals. Do not infer a tax kind from party or delivery addresses. Return amounts and rates shown in the bill; do not calculate missing numbers."

    messages =
      edit_text(request.messages, fn text ->
        [body, boundary] = String.split(text, "\nTax entry boundary: ", parts: 2)
        true = String.contains?(body, generic)

        String.replace(
          body,
          generic,
          "- " <>
            String.trim(boundary) <> " Never infer a tax kind from party or delivery addresses."
        )
      end)

    %{request | messages: messages}
  end

  defp edit_text(messages, fun) do
    Enum.map(messages, fn
      %{role: "user", content: [first | rest]} = message ->
        %{message | content: [%{first | text: fun.(first.text)} | rest]}

      message ->
        message
    end)
  end
end
