defmodule Nila.Gst.Extraction.MistralChatFinch do
  @moduledoc false

  @pool_options [
    protocols: [:http2],
    http2: [ping_interval: :timer.seconds(30)]
  ]

  @doc false
  def child_spec(_opts) do
    # Chat is the part of extraction that benefits from connection reuse: page
    # discovery runs four requests concurrently and invoice extraction runs
    # eight. A pure HTTP/2 pool multiplexes that fan-out without accumulating
    # the idle HTTP/1 sockets that caused the OCR failure investigated in
    # docs/mistral-http-transport.md.
    #
    # Keep this pure H2. Finch's mixed [:http1, :http2] ALPN mode is an HTTP/1
    # style pool without multiplexing and has a known large-body flow-control
    # failure. The explicit origin also starts the known pool with the
    # application instead of waiting for the first extraction call to create it.
    Supervisor.child_spec(
      {Finch, name: __MODULE__, pools: %{origin() => @pool_options}},
      id: __MODULE__
    )
  end

  @doc false
  def req_options, do: [finch: [name: __MODULE__]]

  @doc false
  def pool_options, do: @pool_options

  @doc false
  def origin do
    uri = URI.parse(base_url())

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      uri
      |> Map.put(:path, nil)
      |> Map.put(:query, nil)
      |> Map.put(:fragment, nil)
      |> Map.put(:userinfo, nil)
      |> URI.to_string()
    else
      raise ArgumentError, "invalid Mistral base URL: #{inspect(base_url())}"
    end
  end

  defp base_url do
    chat = Application.get_env(:nila, Nila.Gst.Extraction.Providers.MistralChat, [])
    documents = Application.get_env(:nila, Nila.Gst.Extraction.Providers.Mistral, [])
    chat[:base_url] || documents[:base_url] || "https://api.mistral.ai"
  end
end
