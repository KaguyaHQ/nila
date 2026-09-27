defmodule NilaWeb.ApiContractTest do
  use ExUnit.Case, async: true
  alias NilaWeb.ApiContract, as: Contract

  test "every React API route has a contract and every documented route exists" do
    routes = NilaWeb.Router.__routes__()

    normalized = fn path ->
      Regex.replace(~r/:([a-z_]+)/, String.trim_trailing(path, "/"), "{\\1}")
    end

    spec = Contract.spec()

    for route <- routes,
        String.starts_with?(route.path, ["/api/workspace/", "/api/business"]) do
      path = normalized.(route.path)

      assert get_in(spec, ["paths", path, to_string(route.verb)]),
             "Missing OpenAPI operation: #{route.verb} #{path}"
    end

    ids =
      for {path, operations} <- spec["paths"],
          {verb, operation} <- operations,
          verb in ~w(get post put patch delete head options trace) do
        assert Enum.any?(routes, &(normalized.(&1.path) == path and to_string(&1.verb) == verb)),
               "OpenAPI documents a route that does not exist: #{verb} #{path}"

        operation["operationId"]
      end

    assert length(ids) == length(Enum.uniq(ids)), "Operation IDs must be unique"
  end

  test "purchase treatment requires selected records, evidence and a supported decision" do
    body = %{
      "case_ids" => [1],
      "basis" => %{"1" => "evidence"},
      "values" => %{"choice" => "later"}
    }

    assert {:ok, _} = Contract.validate("PurchaseTreatment", body)
    assert {:error, _} = Contract.validate("PurchaseTreatment", Map.delete(body, "basis"))
    assert {:error, _} = Contract.validate("PurchaseTreatment", Map.put(body, "case_ids", []))

    assert {:error, _} =
             Contract.validate("PurchaseTreatment", put_in(body, ["values", "choice"], "ignore"))
  end

  test "client writes cannot describe fields owned by the server" do
    assert {:ok, _} =
             Contract.validate("ClientWrite", %{"client" => %{"name" => "Client", "gstin" => nil}})

    assert {:error, _} =
             Contract.validate("ClientWrite", %{"client" => %{"name" => "Client", "org_id" => 2}})
  end

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
