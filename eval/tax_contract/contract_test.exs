Code.require_file("eval/tax_contract/candidates.exs")
ExUnit.start()

defmodule Nila.Eval.TaxContractTest do
  use ExUnit.Case, async: true
  alias Nila.Eval.TaxCandidates
  alias Nila.Gst.Extraction.InvoiceRequest

  defp original, do: InvoiceRequest.build(:sales, [{1, "test source"}], :text, :semantic)
  defp prompt(request), do: hd(List.last(request.messages).content).text

  test "printed example adds only one example and preserves schema and source parts" do
    base = original()
    candidate = TaxCandidates.build(base, "printed-example")
    assert candidate.schema == base.schema
    assert String.starts_with?(prompt(candidate), prompt(base))
    assert String.contains?(prompt(candidate), "The item's printed_tax_components has one entry")
    assert tl(List.last(candidate.messages).content) == tl(List.last(base.messages).content)
  end

  test "footer-rate changes only the summary schema and leaves source and instructions intact" do
    original = original()
    candidate = TaxCandidates.build(original, "footer-rate")
    schema = original.schema |> Jason.encode!() |> Jason.decode!()
    assert candidate.messages == original.messages

    assert Map.keys(candidate.schema["properties"]["printed_tax_totals"]["items"]["properties"])
           |> Enum.sort() == ~w(printed_amount printed_label printed_rate)

    restored =
      put_in(
        candidate.schema,
        ["properties", "printed_tax_totals"],
        schema["properties"]["printed_tax_totals"]
      )

    assert restored == schema
    JSV.build!(candidate.schema)
  end

  test "three kind variations have bounded differences from the scoped baseline" do
    base = TaxCandidates.build(original(), "scoped-kind")
    renamed = TaxCandidates.build(original(), "observed-kind")

    assert renamed.schema
           |> Jason.encode!()
           |> String.replace("\"observed_kind\"", "\"kind\"")
           |> Jason.decode!() == base.schema

    assert String.replace(prompt(renamed), "observed_kind", "kind") == prompt(base)

    example = TaxCandidates.build(original(), "mixed-example")
    assert example.schema == base.schema
    assert String.starts_with?(prompt(example), prompt(base))

    single = TaxCandidates.build(original(), "single-rule")
    assert single.schema == base.schema
    refute String.contains?(prompt(single), "Understand each tax from")
    refute String.contains?(prompt(single), "Tax entry boundary:")

    assert String.contains?(
             prompt(single),
             "A generic item GST amount remains one combined entry"
           )

    for arm <- ~w(production footer-rate scoped-kind observed-kind mixed-example single-rule) do
      request = TaxCandidates.build(original(), arm)
      JSV.build!(request.schema)
      assert tl(List.last(request.messages).content) == tl(List.last(original().messages).content)
    end
  end
end
