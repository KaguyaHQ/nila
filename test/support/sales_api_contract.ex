defmodule NilaWeb.SalesApiContract do
  @moduledoc false
  import ExUnit.Assertions

  def contract_response(conn, status) do
    body = Phoenix.ConnTest.json_response(conn, status)
    spec = spec()

    {_path, operations} =
      Enum.find(spec["paths"], fn {path, _} ->
        expected = String.split(path, "/")
        actual = String.split(conn.request_path, "/")

        length(expected) == length(actual) and
          Enum.zip(expected, actual)
          |> Enum.all?(fn {a, b} -> String.starts_with?(a, "{") or a == b end)
      end) || flunk("No sales contract for #{conn.request_path}")

    operation = operations[String.downcase(conn.method)]
    assert operation, "No sales contract for #{conn.method} #{conn.request_path}"

    schema =
      get_in(operation, ["responses", to_string(status), "content", "application/json", "schema"])

    assert schema, "Undocumented response status #{status}"
    assert_valid(spec, schema, body)

    # Invalid and stale requests are deliberately exercised by controller tests.
    # Validate accepted request bodies; domain rules still belong to Phoenix.
    if status in 200..299 and operation["requestBody"] do
      request_schema = get_in(operation, ["requestBody", "content", "application/json", "schema"])
      assert_valid(spec, request_schema, Jason.decode!(Jason.encode!(conn.body_params)))
    end

    body
  end

  def spec do
    :nila
    |> Application.app_dir("priv/openapi/sales-workspace.json")
    |> File.read!()
    |> Jason.decode!()
  end

  def validate(schema_name, body) do
    spec = spec()
    schema = %{"$ref" => "#/components/schemas/#{schema_name}"}
    JSV.validate(body, root(spec, schema))
  end

  defp assert_valid(spec, schema, body) do
    case JSV.validate(body, root(spec, schema)) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        flunk(
          "Sales API contract mismatch: #{inspect(JSV.normalize_error(error), pretty: true, limit: :infinity)}"
        )
    end
  end

  defp root(spec, schema), do: schema |> Map.put("components", spec["components"]) |> JSV.build!()
end
