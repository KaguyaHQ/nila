defmodule Nila.AssistantTest do
  use Nila.DataCase, async: false

  alias Nila.Accounts.Scope
  alias Nila.Assistant
  alias Nila.Assistant.HTTPClient.Stub
  alias Nila.Orgs

  setup do
    org =
      Orgs.create_org!(%{
        name: "Assistant Test Org #{System.unique_integer([:positive])}",
        legal_name: "Assistant Test Private Limited",
        gstin: "29ABCDE1234F1ZW"
      })

    scope = %Scope{user: nil, current_org: org, membership: nil}
    %{scope: scope, org: org}
  end

  defp text_response(text) do
    {:ok,
     %{
       status: 200,
       body: %{
         "choices" => [
           %{
             "finish_reason" => "stop",
             "message" => %{"role" => "assistant", "content" => text}
           }
         ]
       }
     }}
  end

  describe "chat/2" do
    test "returns an assembled turn for a text-only response", %{scope: scope} do
      Stub.put_responses(text_response("Hello, how can I help?"))

      turns = [%{role: :user, text: "hi", id: 1}]
      assert {:ok, %{turn: turn}} = Assistant.chat(scope, turns)
      assert turn.role == :assistant
      assert turn.text == "Hello, how can I help?"
      assert turn.attachments == []
    end

    # NOTE: tool-loop coverage (tool_calls → tool result → text, and the
    # max-iteration cap) was dropped when the `search_documents` tool was
    # retired with the generic Documents context. `Nila.Assistant.Tools.specs/0`
    # is empty; restore these tests alongside the first real GST-facing tool.

    test "maps 429 to :rate_limited", %{scope: scope} do
      Stub.put_responses({:ok, %{status: 429, body: %{}}})

      assert {:error, :rate_limited} =
               Assistant.chat(scope, [%{role: :user, text: "hi", id: 1}])
    end

    test "maps network errors to :network", %{scope: scope} do
      Stub.put_responses({:error, :nxdomain})

      assert {:error, :network} =
               Assistant.chat(scope, [%{role: :user, text: "hi", id: 1}])
    end

    test "maps 401 to :bad_request", %{scope: scope} do
      Stub.put_responses({:ok, %{status: 401, body: %{}}})

      assert {:error, :bad_request} =
               Assistant.chat(scope, [%{role: :user, text: "hi", id: 1}])
    end

    test "sends Authorization: Bearer header and chat/completions URL", %{scope: scope} do
      Stub.put_responses(text_response("ok"))

      {:ok, _} = Assistant.chat(scope, [%{role: :user, text: "hi", id: 1}])

      config = Application.fetch_env!(:nila, Nila.Assistant)
      [{url, body, headers}] = Stub.calls()
      assert url == config[:base_url] <> "/chat/completions"
      assert headers["authorization"] =~ ~r/^Bearer /
      assert body["model"] == config[:model]
      assert is_list(body["tools"])
      assert [%{"role" => "system"} | _] = body["messages"]
    end

    test "merges configured extra_headers into the request (gateway routing)", %{scope: scope} do
      original = Application.fetch_env!(:nila, Nila.Assistant)

      on_exit(fn -> Application.put_env(:nila, Nila.Assistant, original) end)

      Application.put_env(
        :nila,
        Nila.Assistant,
        Keyword.put(original, :extra_headers, %{"x-portkey-provider" => "openai"})
      )

      Stub.put_responses(text_response("ok"))
      {:ok, _} = Assistant.chat(scope, [%{role: :user, text: "hi", id: 1}])

      [{_url, _body, headers}] = Stub.calls()
      assert headers["x-portkey-provider"] == "openai"
      assert headers["authorization"] =~ ~r/^Bearer /
    end

    test "streams deltas and trace events when a trace topic is provided", %{scope: scope} do
      topic = "assistant-test:#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Nila.PubSub, topic)
      Stub.put_responses(text_response("Hi"))

      assert {:ok, %{turn: turn}} =
               Assistant.chat(scope, [%{role: :user, text: "hi", id: 1}], trace_topic: topic)

      assert turn.text == "Hi"
      assert_received {:assistant_trace, %{title: "Thinking…", status: :running}}
      assert_received {:assistant_delta, "H"}
      assert_received {:assistant_delta, "i"}
      assert_received {:assistant_trace, %{title: "Answer ready", status: :done}}
    end
  end

  describe "system_prompt/0" do
    test "includes today's date" do
      today = Date.utc_today() |> Date.to_iso8601()
      assert Assistant.system_prompt() =~ today
    end
  end
end
