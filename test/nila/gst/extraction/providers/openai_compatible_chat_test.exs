defmodule Nila.Gst.Extraction.Providers.OpenAICompatibleChatTest do
  use ExUnit.Case, async: false

  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat

  @schema %{
    type: "object",
    additionalProperties: false,
    required: ["ok"],
    properties: %{ok: %{type: "boolean"}}
  }

  test "does not retry a terminal provider response" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      Agent.update(calls, &(&1 + 1))
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad schema"})
    end)

    assert {:ok, %{status: 400}} = OpenAICompatibleChat.request_raw([], "test", @schema)
    assert Agent.get(calls, & &1) == 1
  end

  test "returns an exhausted rate limit as infrastructure failure, not model output" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      Agent.update(calls, &(&1 + 1))
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "slow down"})
    end)

    assert {:ok, response} =
             OpenAICompatibleChat.request_raw([], "test", @schema, max_retries: 0)

    assert {:error, {:text_chat_failed, 429, %{"error" => "slow down"}}} =
             OpenAICompatibleChat.decode(response)

    assert Agent.get(calls, & &1) == 1
  end

  test "swaps endpoint, key, model, and provider identity through config" do
    previous = Application.get_env(:nila, OpenAICompatibleChat)

    Application.put_env(:nila, OpenAICompatibleChat,
      provider: "tencent-tokenhub",
      base_url: "https://tokenhub.tencentmaas.com/v1/",
      api_key: "tokenhub-key",
      model: "hy3",
      req_options: [plug: {Req.Test, OpenAICompatibleChat}]
    )

    on_exit(fn -> Application.put_env(:nila, OpenAICompatibleChat, previous) end)

    Req.Test.expect(OpenAICompatibleChat, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tokenhub-key"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["model"] == "hy3"
      assert payload["response_format"]["json_schema"]["strict"]

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(%{"ok" => true})}}]
      })
    end)

    assert OpenAICompatibleChat.provider() == "tencent-tokenhub"
    assert OpenAICompatibleChat.model() == "hy3"
    assert OpenAICompatibleChat.fingerprint("prompt", @schema).provider == "tencent-tokenhub"

    assert {:ok, response} = OpenAICompatibleChat.request_raw([], "test", @schema)
    assert {:ok, %{"ok" => true}, %{}} = OpenAICompatibleChat.decode(response, @schema)
  end

  test "json_object puts the schema in the prompt and validates locally" do
    Req.Test.expect(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["response_format"] == %{"type" => "json_object"}
      assert [%{"role" => "system", "content" => instruction}] = payload["messages"]
      assert instruction =~ "validates against this JSON Schema"
      assert instruction =~ "additionalProperties"

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(%{"ok" => true})}}]
      })
    end)

    assert {:ok, response} =
             OpenAICompatibleChat.request_raw([], "test", @schema, response_format: :json_object)

    assert {:ok, %{"ok" => true}, %{}} = OpenAICompatibleChat.decode(response, @schema)
  end

  test "local validation rejects wrong keys and types" do
    body =
      Jason.encode!(%{
        "choices" => [%{"message" => %{"content" => Jason.encode!(%{"answer" => "yes"})}}]
      })

    assert {:error, {:text_chat_schema_mismatch, _errors}} =
             OpenAICompatibleChat.decode(
               %{status: 200, body: body, response_format: :json_object},
               @schema
             )
  end

  test "strict schema mode does not retry a malformed successful response" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      Agent.update(calls, &(&1 + 1))

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => "not json"}}]
      })
    end)

    assert {:ok, _response} =
             OpenAICompatibleChat.request_raw([], "test", @schema, max_retries: 2)

    assert Agent.get(calls, & &1) == 1
  end

  test "json_object retries a schema mismatch through the normal request path" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      attempt = Agent.get_and_update(calls, &{&1, &1 + 1})
      content = if attempt == 0, do: %{"answer" => "yes"}, else: %{"ok" => true}

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}]
      })
    end)

    assert {:ok, response} =
             OpenAICompatibleChat.request_raw([], "test", @schema,
               response_format: :json_object,
               max_retries: 1
             )

    assert {:ok, %{"ok" => true}, %{}} = OpenAICompatibleChat.decode(response, @schema)
    assert Agent.get(calls, & &1) == 2
  end
end
