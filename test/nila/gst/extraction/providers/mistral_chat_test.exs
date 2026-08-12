defmodule Nila.Gst.Extraction.Providers.MistralChatTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Providers.MistralChat

  test "retries rate limits and proven HTTP/2 pre-send failures" do
    request = Req.new()

    assert MistralChat.retry_policy(request, %Req.Response{status: 429}) == {:delay, 1_000}

    assert MistralChat.retry_policy(request, %Req.HTTPError{
             protocol: :http2,
             reason: :pool_not_available
           }) == {:delay, 200}

    assert MistralChat.retry_policy(request, %Req.HTTPError{
             protocol: :http2,
             reason: :connection_not_ready
           }) == {:delay, 200}

    assert MistralChat.retry_policy(request, %Req.HTTPError{
             protocol: :http2,
             reason: :unprocessed
           }) == {:delay, 200}
  end

  test "does not replay ambiguous transport failures" do
    request = Req.new()

    refute MistralChat.retry_policy(request, %Req.TransportError{reason: :closed})
    refute MistralChat.retry_policy(request, %Req.TransportError{reason: :timeout})
    refute MistralChat.retry_policy(request, %Req.Response{status: 400})
  end
end
