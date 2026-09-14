Code.require_file("requests.exs", __DIR__)
ExUnit.start()

defmodule Nila.Eval.RequestsTest do
  use ExUnit.Case, async: true
  alias Nila.Eval.Requests

  setup do
    dir = Path.join(System.tmp_dir!(), "nila-eval-capture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  @schema %{
    type: "object",
    properties: %{amount: %{type: "number"}},
    required: ["amount"],
    additionalProperties: false
  }
  @payload %{"model" => "test", "messages" => []}

  test "saves the exact prepared request and raw response, with local validation", %{dir: dir} do
    body =
      Jason.encode!(%{
        choices: [%{finish_reason: "stop", message: %{content: ~s({"amount":1180})}}],
        usage: %{completion_tokens: 8}
      })

    response = %Req.Response{
      status: 200,
      body: body,
      headers: %{"set-cookie" => ["private"], "x-request-id" => ["abc"]}
    }

    {result, meta, decoded} =
      Requests.capture(dir, "001", @payload, @schema, fn -> {:ok, response} end)

    assert result == {:ok, response}
    assert {:ok, %{"amount" => 1180}, _} = decoded
    assert meta.local_schema_valid
    assert meta.usage == %{"completion_tokens" => 8}
    assert File.read!(Path.join(dir, "001-response.json")) == body
    assert Jason.decode!(File.read!(Path.join(dir, "001-request.json"))) == @payload

    assert Jason.decode!(File.read!(Path.join(dir, "001-headers.json"))) == %{
             "x-request-id" => ["abc"]
           }

    assert_raise RuntimeError, ~r/overwrite/, fn ->
      Requests.capture(dir, "001", @payload, @schema, fn -> flunk("must not resend") end)
    end
  end

  test "HTTP success is not schema success", %{dir: dir} do
    body =
      Jason.encode!(%{
        choices: [%{finish_reason: "stop", message: %{content: ~s({"amount":null})}}]
      })

    {_, meta, decoded} =
      Requests.capture(dir, "invalid", @payload, @schema, fn ->
        {:ok, %Req.Response{status: 200, body: body}}
      end)

    assert meta.http_status == 200
    refute meta.local_schema_valid
    assert {:error, _} = decoded
  end

  test "records a transport failure without retrying", %{dir: dir} do
    error = %RuntimeError{message: "offline"}

    {result, meta, _} =
      Requests.capture(dir, "failed", @payload, @schema, fn -> {:error, error} end)

    assert result == {:error, error}
    assert meta.outcome == "transport_error"
    refute Map.has_key?(meta, :http_status)
  end

  test "malformed provider envelopes remain recorded failures", %{dir: dir} do
    for {envelope, index} <-
          Enum.with_index([
            %{"choices" => %{}},
            %{"choices" => [%{"message" => "bad"}]},
            %{"choices" => [nil]}
          ]) do
      body = Jason.encode!(envelope)

      {_, meta, decoded} =
        Requests.capture(dir, "malformed-#{index}", @payload, @schema, fn ->
          {:ok, %Req.Response{status: 200, body: body}}
        end)

      assert meta.http_status == 200
      refute meta.local_schema_valid
      assert {:error, _} = decoded
    end
  end
end
