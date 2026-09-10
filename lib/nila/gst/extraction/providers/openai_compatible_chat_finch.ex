defmodule Nila.Gst.Extraction.Providers.OpenAICompatibleChatFinch do
  @moduledoc false

  @http2_pool_options [
    protocols: [:http2],
    http2: [ping_interval: :timer.seconds(30)]
  ]
  @http1_pool_options [protocols: [:http1]]

  @doc false
  def child_spec(_opts) do
    # Text extraction fans out across pages and invoice segments. Protocol is a
    # provider setting because Finch mixed ALPN does not multiplex HTTP/2; known
    # HTTP/2 providers retain the pure pool while TokenHub uses pure HTTP/1.
    Supervisor.child_spec(
      {Finch, name: __MODULE__, pools: %{origin() => pool_options()}},
      id: __MODULE__
    )
  end

  @doc false
  def req_options, do: [finch: [name: __MODULE__]]

  @doc false
  def pool_options do
    case config()[:protocol] || :http2 do
      :http1 -> @http1_pool_options
      :http2 -> @http2_pool_options
    end
  end

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
      raise ArgumentError, "invalid GST text base URL: #{inspect(base_url())}"
    end
  end

  defp base_url, do: Nila.Gst.Extraction.Providers.OpenAICompatibleChat.base_url()
  defp config, do: Application.get_env(:nila, __MODULE__, [])
end
