defmodule Nila.Gst.Extraction.OpenAICompatibleChatFinchTest do
  use ExUnit.Case, async: false

  alias Nila.Gst.Extraction.OpenAICompatibleChatFinch

  test "uses HTTP/2 for a provider configured for multiplexing" do
    assert %{start: {Finch, :start_link, [options]}} =
             OpenAICompatibleChatFinch.child_spec([])

    assert options[:name] == OpenAICompatibleChatFinch

    assert options[:pools] == %{
             "https://api.mistral.ai" => [
               protocols: [:http2],
               http2: [ping_interval: :timer.seconds(30)]
             ]
           }
  end

  test "uses pure HTTP/1 for TokenHub" do
    previous_chat =
      Application.get_env(:nila, Nila.Gst.Extraction.Providers.OpenAICompatibleChat)

    previous_finch = Application.get_env(:nila, OpenAICompatibleChatFinch)

    Application.put_env(:nila, Nila.Gst.Extraction.Providers.OpenAICompatibleChat,
      base_url: "https://tokenhub.tencentmaas.com/v1"
    )

    Application.put_env(:nila, OpenAICompatibleChatFinch, protocol: :http1)

    on_exit(fn ->
      Application.put_env(
        :nila,
        Nila.Gst.Extraction.Providers.OpenAICompatibleChat,
        previous_chat
      )

      Application.put_env(:nila, OpenAICompatibleChatFinch, previous_finch)
    end)

    assert %{start: {Finch, :start_link, [options]}} =
             OpenAICompatibleChatFinch.child_spec([])

    assert options[:pools] == %{
             "https://tokenhub.tencentmaas.com" => [protocols: [:http1]]
           }

    assert OpenAICompatibleChatFinch.req_options() == [
             finch: [name: OpenAICompatibleChatFinch]
           ]
  end
end
