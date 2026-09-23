defmodule NilaWeb.ApiContract do
  @moduledoc false
  import ExUnit.Assertions

  def contract_response(conn, status, opts \\ []) do
    body = Phoenix.ConnTest.json_response(conn, status)
    spec = spec()

    operation = operation(conn, spec)

    schema =
      get_in(operation, ["responses", to_string(status), "content", "application/json", "schema"])

    assert schema, "Undocumented response status #{status}"
    assert_valid(spec, schema, body)

    # Invalid and stale requests are deliberately exercised by controller tests.
    # Validate accepted request bodies; domain rules still belong to Phoenix.
    if (status in 200..299 and operation["requestBody"]) && Keyword.get(opts, :request, true) do
      content = operation["requestBody"]["content"]
      request_schema = (content["application/json"] || content["multipart/form-data"])["schema"]

      params =
        Map.new(conn.body_params, fn
          {key, %Plug.Upload{filename: filename}} -> {key, filename}
          pair -> pair
        end)

      assert_valid(spec, request_schema, Jason.decode!(Jason.encode!(params)))
    end

    body
  end

  def contract_file(conn, status) do
    bytes = Phoenix.ConnTest.response(conn, status)
    operation = operation(conn, spec())
    response = operation["responses"][to_string(status)]
    assert response, "Undocumented response status #{status}"
    media = conn |> Plug.Conn.get_resp_header("content-type") |> hd() |> String.split(";") |> hd()
    assert response["content"][media], "Undocumented content type #{media}"
    assert is_binary(bytes)
    bytes
  end

  defp operation(conn, spec) do
    %{route: route} =
      Phoenix.Router.route_info(NilaWeb.Router, conn.method, conn.request_path, conn.host)

    path = Regex.replace(~r/:([a-z_]+)/, String.trim_trailing(route, "/"), "{\\1}")
    operation = get_in(spec, ["paths", path, String.downcase(conn.method)])
    assert operation, "No API contract for #{conn.method} #{path}"
    operation
  end

  def spec do
    :nila
    |> Application.app_dir("priv/openapi/workspace.json")
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
          "API contract mismatch: #{inspect(JSV.normalize_error(error), pretty: true, limit: :infinity)}"
        )
    end
  end

  defp root(spec, schema), do: schema |> Map.put("components", spec["components"]) |> JSV.build!()
end
