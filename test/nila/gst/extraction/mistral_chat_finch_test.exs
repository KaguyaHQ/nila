defmodule Nila.Gst.Extraction.MistralChatFinchTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.MistralChatFinch

  test "uses a pure HTTP/2 pool for the known Mistral origin" do
    assert %{start: {Finch, :start_link, [options]}} = MistralChatFinch.child_spec([])

    assert options[:name] == MistralChatFinch

    assert options[:pools] == %{
             "https://api.mistral.ai" => [
               protocols: [:http2],
               http2: [ping_interval: :timer.seconds(30)]
             ]
           }

    assert MistralChatFinch.req_options() == [finch: [name: MistralChatFinch]]
  end
end
