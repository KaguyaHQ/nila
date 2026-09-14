defmodule Nila.Gst.Extraction.InvoicePromptTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.{InvoicePrompt, InvoiceSchema}

  defp examples do
    Regex.scan(~r/```json\r?\n(.*?)\r?\n```/s, InvoicePrompt.amount_examples(),
      capture: :all_but_first
    )
    |> Enum.map(fn [json] -> Jason.decode!(json) end)
  end

  test "every worked example follows the actual positional schema for both invoice kinds" do
    examples = examples()
    assert length(examples) == 4

    for kind <- [:sales, :purchase], example <- examples do
      # The examples show selected invoice fields, but complete item rows.
      schema = %{InvoiceSchema.tuple_schema(kind) | required: Map.keys(example)}
      assert {:ok, _} = JSV.validate(example, JSV.build!(schema))
    end
  end

  test "examples distinguish row amounts, taxable values and footer evidence" do
    [gross, separate, inclusive, footer] =
      Enum.map(examples(), &InvoiceSchema.decode_line_items/1)

    [gross_row] = gross["line_items"]
    assert gross_row["printed_line_total"] == 1180
    assert is_nil(gross_row["printed_line_amount"])
    assert is_nil(gross_row["printed_taxable_value"])
    assert gross_row["line_amount_tax_inclusion"] == "unknown"

    assert [%{"printed_label" => "GST", "printed_amount" => 180}] =
             gross_row["printed_tax_components"]

    assert gross["printed_total_taxable"] == 1000

    [separate_row] = separate["line_items"]
    assert separate_row["printed_line_amount"] == 1000
    assert separate_row["printed_line_total"] == 1180
    assert is_nil(separate_row["printed_taxable_value"])

    [inclusive_row] = inclusive["line_items"]
    assert inclusive_row["printed_line_amount"] == 1180
    assert is_nil(inclusive_row["printed_line_total"])
    assert inclusive_row["line_amount_tax_inclusion"] == "inclusive"
    assert inclusive_row["printed_tax_components"] == []

    assert Enum.map(footer["line_items"], & &1["printed_taxable_value"]) == [200, 50]

    assert Enum.all?(footer["line_items"], fn row ->
             is_nil(row["printed_line_amount"]) and row["printed_tax_components"] == []
           end)

    assert Enum.map(footer["printed_tax_totals"], & &1["printed_amount"]) == [22.5, 22.5]
    assert footer["printed_grand_total"] == 295
  end

  test "semantic examples validate and reach accounting without changing their numbers" do
    examples =
      Regex.scan(~r/```json\r?\n(.*?)\r?\n```/s, InvoicePrompt.amount_examples(:semantic),
        capture: :all_but_first
      )
      |> Enum.map(fn [json] -> Jason.decode!(json) end)

    assert length(examples) == 4

    for example <- examples do
      schema = %{InvoiceSchema.tuple_schema(:sales, :semantic) | required: Map.keys(example)}
      assert {:ok, _} = JSV.validate(example, JSV.build!(schema))
    end

    [gross, separate, inclusive, footer] =
      Enum.map(examples, &InvoiceSchema.decode_line_items(&1, :semantic))

    [gross_row] = gross["line_items"]
    assert gross_row["printed_line_total"] == 1180
    assert gross_row["printed_taxable_value"] == nil
    assert Nila.Gst.LineAmounts.taxable_value(gross_row) == 1000

    [separate_row] = separate["line_items"]
    assert separate_row["printed_taxable_value"] == 1000
    assert separate_row["printed_line_total"] == 1180
    assert Nila.Gst.LineAmounts.taxable_value(separate_row) == 1000

    [inclusive_row] = inclusive["line_items"]
    assert inclusive_row["printed_line_total"] == 1180
    assert inclusive_row["printed_taxable_value"] == nil
    # A gross figure without item tax evidence stays unresolved, never becomes zero.
    assert Nila.Gst.LineAmounts.taxable_value(inclusive_row) == nil
    assert Enum.map(footer["line_items"], & &1["printed_taxable_value"]) == [200, 50]
    assert footer["printed_tax_totals"] == Enum.at(examples, 3)["printed_tax_totals"]

    for invoice <- [gross, separate, inclusive, footer], row <- invoice["line_items"] do
      assert row["printed_line_amount"] == nil
      assert row["line_amount_tax_inclusion"] == "unknown"
      refute Map.has_key?(row, "amount_before_gst")
      refute Map.has_key?(row, "amount_including_gst")
    end
  end

  test "missing identifiers and signed rounding can be represented without invented values" do
    for kind <- [:sales, :purchase] do
      schema = InvoiceSchema.tuple_schema(kind)

      for field <- [:invoice_number, :invoice_date] do
        assert {:ok, nil} = JSV.validate(nil, JSV.build!(schema.properties[field]))
      end

      assert {:ok, -0.2} =
               JSV.validate(-0.2, JSV.build!(schema.properties.printed_rounding_adjustment))
    end
  end
end
