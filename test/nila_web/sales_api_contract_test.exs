defmodule NilaWeb.SalesApiContractTest do
  use ExUnit.Case, async: true
  alias NilaWeb.SalesApiContract, as: Contract

  test "line corrections require a line index while facts can clear a value" do
    assert {:ok, _} =
             Contract.validate("ReviewChange", %{
               "section" => "facts",
               "values" => %{"buyer_gstin" => nil}
             })

    line = %{"section" => "line", "values" => %{"quantity" => "2"}}
    assert {:error, _} = Contract.validate("ReviewChange", line)
    assert {:ok, _} = Contract.validate("ReviewChange", Map.put(line, "line_index", 0))
    assert {:error, _} = Contract.validate("ReviewChange", Map.put(line, "line_index", -1))
  end

  test "upload preparation accepts either files or renewal, with the current size limit" do
    file = %{"name" => "sales.pdf", "size" => 50_000_000}
    assert {:ok, _} = Contract.validate("PrepareUpload", %{"files" => [file]})
    assert {:ok, _} = Contract.validate("PrepareUpload", %{"token" => "signed-token"})
    assert {:error, _} = Contract.validate("PrepareUpload", %{"files" => []})

    assert {:error, _} =
             Contract.validate("PrepareUpload", %{"files" => [Map.put(file, "size", 50_000_001)]})

    assert {:error, _} =
             Contract.validate("PrepareUpload", %{"files" => [file], "token" => "signed-token"})
  end

  test "monthly decisions require the evidence basis and a supported action" do
    decision = %{
      "target" => "sequence_gaps",
      "basis" => "current-evidence",
      "action" => "confirm"
    }

    assert {:ok, _} = Contract.validate("MonthlySalesDecision", decision)
    assert {:error, _} = Contract.validate("MonthlySalesDecision", Map.delete(decision, "basis"))

    assert {:error, _} =
             Contract.validate("MonthlySalesDecision", Map.put(decision, "action", "ignore"))
  end
end
