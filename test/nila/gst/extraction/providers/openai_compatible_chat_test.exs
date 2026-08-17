defmodule Nila.Gst.Extraction.Providers.OpenAICompatibleChatTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

    assert {:ok, %{status: 400, retry_count: 0}} =
             OpenAICompatibleChat.request_raw([], "test", @schema)

    assert Agent.get(calls, & &1) == 1
  end

  test "returns an exhausted rate limit as infrastructure failure, not model output" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      Agent.update(calls, &(&1 + 1))
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "slow down"})
    end)

    log =
      capture_log(fn ->
        assert {:ok, response} =
                 OpenAICompatibleChat.request_raw([], "test", @schema, max_retries: 0)

        assert {:error, {:text_chat_failed, 429, %{"error" => "slow down"}}} =
                 OpenAICompatibleChat.decode(response)
      end)

    assert log =~ "gst_text.retry_exhausted"
    assert log =~ "reason={:http_status, 429}"
    assert Agent.get(calls, & &1) == 1
  end

  test "a rate-limited caller waits and retries without gating another caller" do
    previous = Application.get_env(:nila, OpenAICompatibleChat)
    parent = self()

    Application.put_env(
      :nila,
      OpenAICompatibleChat,
      Keyword.put(previous, :retry_wait, fn delay ->
        send(parent, {:retry_wait, self(), delay})

        receive do
          :continue -> :ok
        end
      end)
    )

    on_exit(fn -> Application.put_env(:nila, OpenAICompatibleChat, previous) end)

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "2")
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{"error" => "slow down"})

        _later ->
          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"content" => Jason.encode!(%{"ok" => true})}}]
          })
      end
    end)

    log =
      capture_log(
        [
          metadata: [
            :provider,
            :model,
            :retry_kind,
            :http_status,
            :attempt,
            :max_retries,
            :delay_ms
          ]
        ],
        fn ->
          first =
            Task.async(fn ->
              OpenAICompatibleChat.request_raw([], "test", @schema, max_retries: 1)
            end)

          assert_receive {:retry_wait, waiting, delay}, 500
          assert delay in 2_000..2_500

          second =
            Task.async(fn ->
              OpenAICompatibleChat.request_raw([], "test", @schema, max_retries: 1)
            end)

          assert {:ok, second_response} = Task.await(second, 500)

          assert {:ok, %{"ok" => true}, %{}} =
                   OpenAICompatibleChat.decode(second_response, @schema)

          send(waiting, :continue)
          assert {:ok, first_response} = Task.await(first, 500)

          assert {:ok, %{"ok" => true}, %{}} =
                   OpenAICompatibleChat.decode(first_response, @schema)
        end
      )

    assert log =~ "gst_text.retry"
    assert log =~ "retry_kind=http_status"
    assert log =~ "http_status=429"
    assert Agent.get(calls, & &1) == 3
  end

  test "retries a transient provider failure locally" do
    previous = Application.get_env(:nila, OpenAICompatibleChat)
    parent = self()

    Application.put_env(
      :nila,
      OpenAICompatibleChat,
      Keyword.put(previous, :retry_wait, fn delay -> send(parent, {:retry_wait, delay}) end)
    )

    on_exit(fn -> Application.put_env(:nila, OpenAICompatibleChat, previous) end)

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "try again"})
        _later -> successful_response(conn)
      end
    end)

    log =
      capture_log([metadata: [:retry_kind, :http_status, :attempt, :delay_ms]], fn ->
        assert {:ok, response} =
                 OpenAICompatibleChat.request_raw([], "test", @schema, max_retries: 1)

        assert response.retry_count == 1
        assert {:ok, %{"ok" => true}, %{}} = OpenAICompatibleChat.decode(response, @schema)
      end)

    assert_receive {:retry_wait, delay}
    assert delay in 1_000..1_500
    assert log =~ "reason={:http_status, 500}"
    assert log =~ "http_status=500"
    assert Agent.get(calls, & &1) == 2
  end

  test "retries an HTTP/2 pool startup failure locally" do
    previous = Application.get_env(:nila, OpenAICompatibleChat)
    parent = self()

    Application.put_env(
      :nila,
      OpenAICompatibleChat,
      Keyword.put(previous, :retry_wait, fn delay -> send(parent, {:retry_wait, delay}) end)
    )

    on_exit(fn -> Application.put_env(:nila, OpenAICompatibleChat, previous) end)

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 ->
          put_in(
            conn.private[:req_test_exception],
            %Req.HTTPError{protocol: :http2, reason: :pool_not_available}
          )

        _later ->
          successful_response(conn)
      end
    end)

    log =
      capture_log([metadata: [:retry_kind, :transport_reason, :attempt, :delay_ms]], fn ->
        assert {:ok, response} =
                 OpenAICompatibleChat.request_raw([], "test", @schema, max_retries: 1)

        assert response.retry_count == 1
        assert {:ok, %{"ok" => true}, %{}} = OpenAICompatibleChat.decode(response, @schema)
      end)

    assert_receive {:retry_wait, delay}
    assert delay in 0..200
    assert log =~ "reason={:http2, :pool_not_available}"
    assert log =~ "transport_reason=pool_not_available"
    assert Agent.get(calls, & &1) == 2
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

  test "sends provider options and fingerprints them" do
    previous = Application.get_env(:nila, OpenAICompatibleChat)

    Application.put_env(:nila, OpenAICompatibleChat,
      provider: "vercel-ai-gateway",
      base_url: "https://ai-gateway.vercel.sh/v1",
      api_key: "vercel-key",
      model: "alibaba/qwen3.7-flash",
      response_format: :json_schema,
      provider_options: %{"alibaba" => %{"enableThinking" => false}},
      req_options: [plug: {Req.Test, OpenAICompatibleChat}]
    )

    on_exit(fn -> Application.put_env(:nila, OpenAICompatibleChat, previous) end)

    Req.Test.expect(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["providerOptions"] == %{"alibaba" => %{"enableThinking" => false}}

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(%{"ok" => true})}}]
      })
    end)

    assert is_binary(OpenAICompatibleChat.fingerprint("prompt", @schema).provider_options)
    assert {:ok, _response} = OpenAICompatibleChat.request_raw([], "test", @schema)
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

  test "locally validated strict schema retries a mismatch" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["response_format"]["type"] == "json_schema"

      attempt = Agent.get_and_update(calls, &{&1, &1 + 1})
      content = if attempt == 0, do: %{"answer" => "yes"}, else: %{"ok" => true}

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}]
      })
    end)

    assert {:ok, response} =
             OpenAICompatibleChat.request_raw([], "test", @schema,
               response_format: :json_schema_local,
               max_retries: 1
             )

    assert {:ok, %{"ok" => true}, %{}} = OpenAICompatibleChat.decode(response, @schema)
    assert Agent.get(calls, & &1) == 2
  end

  defp successful_response(conn) do
    Req.Test.json(conn, %{
      "choices" => [%{"message" => %{"content" => Jason.encode!(%{"ok" => true})}}]
    })
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
