defmodule Nila.Gst.Extraction.Providers.MistralChatTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Providers.MistralChat

  @schema %{
    type: "object",
    additionalProperties: false,
    required: ["ok"],
    properties: %{ok: %{type: "boolean"}}
  }

  test "does not retry a terminal provider response" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(MistralChat, fn conn ->
      Agent.update(calls, &(&1 + 1))
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad schema"})
    end)

    assert {:ok, %{status: 400}} = MistralChat.request_raw([], "test", @schema)
    assert Agent.get(calls, & &1) == 1
  end

  test "returns an exhausted rate limit as infrastructure failure, not model output" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(MistralChat, fn conn ->
      Agent.update(calls, &(&1 + 1))
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "slow down"})
    end)

    assert {:ok, response} = MistralChat.request_raw([], "test", @schema, max_retries: 0)

    assert {:error, {:mistral_chat_failed, 429, %{"error" => "slow down"}}} =
             MistralChat.decode(response)

    assert Agent.get(calls, & &1) == 1
  end
end
