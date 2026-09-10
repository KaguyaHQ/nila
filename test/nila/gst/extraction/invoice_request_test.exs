defmodule Nila.Gst.Extraction.InvoiceRequestTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.{InvoicePrompt, InvoiceRequest, InvoiceSchema}

  @snapshots "test/fixtures/extraction/invoice_requests.json"
             |> File.read!()
             |> Jason.decode!()

  test "requests match the reviewed instructions and response schemas" do
    for {kind, modality} <- [{:sales, :text}, {:sales, :vision}, {:purchase, :vision}] do
      expected = @snapshots["#{kind}_#{modality}"]

      input =
        if modality == :text do
          expected["messages"]
          |> List.last()
          |> Map.fetch!("content")
          |> Enum.at(1)
          |> Map.fetch!("text")
          |> String.replace_prefix("PHYSICAL PAGE 1\n", "")
        else
          %{bytes: <<255, 216, 255, 217>>, content_type: "image/jpeg"}
        end

      request = InvoiceRequest.build(kind, [{1, input}], modality)
      assert comparable(json(request.messages)) == comparable(expected["messages"])

      assert comparable(json(request.schema)) ==
               comparable(expected["response_format"]["json_schema"]["schema"])

      assert request.name == expected["response_format"]["json_schema"]["name"]
    end
  end

  test "every defined line field reaches the positional schema and decoder in the same order" do
    fields = InvoiceSchema.line_item_fields()

    for kind <- [:sales, :purchase] do
      base =
        get_in(InvoiceSchema.object_schema(kind), [:properties, :line_items, :items, :properties])

      tuple = get_in(InvoiceSchema.tuple_schema(kind), [:properties, :line_items, :items])
      assert MapSet.new(fields) == MapSet.new(Map.keys(base))
      assert tuple.prefixItems == Enum.map(fields, &Map.fetch!(base, &1))
      values = Enum.to_list(1..length(fields))

      assert %{"line_items" => [row]} =
               InvoiceSchema.decode_line_items(%{"line_items" => [values]})

      assert Enum.map(fields, &Map.fetch!(row, to_string(&1))) == values
      assert InvoicePrompt.build(kind, [1], :text) =~ Enum.join(fields, ", ")
    end
  end

  test "text requests preserve page order and text without passing images" do
    request = InvoiceRequest.build(:sales, [{3, "₹0.410"}, {4, "Terms"}], :text)
    [_instruction | pages] = List.last(request.messages).content

    assert pages == [
             %{type: "text", text: "PHYSICAL PAGE 3\n₹0.410"},
             %{type: "text", text: "PHYSICAL PAGE 4\nTerms"}
           ]
  end

  # JSON Schema required is an unordered set. Source files may use LF or CRLF;
  # neither difference changes the reading rules or response field definitions.
  defp comparable(value) when is_map(value) do
    Map.new(value, fn
      {"required", fields} -> {"required", Enum.sort(fields)}
      {key, item} -> {key, comparable(item)}
    end)
  end

  defp comparable(value) when is_list(value), do: Enum.map(value, &comparable/1)
  defp comparable(value) when is_binary(value), do: String.replace(value, "\r\n", "\n")
  defp comparable(value), do: value

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
