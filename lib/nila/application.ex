defmodule Nila.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        NilaWeb.Telemetry,
        Nila.Repo,
        Nila.Gst.Sales.SourceSpreadsheet.Cache
      ] ++
        text_chat_children() ++
        [
          {Oban, Application.fetch_env!(:nila, Oban)},
          {DNSCluster, query: Application.get_env(:nila, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Nila.PubSub},
          NilaWeb.Presence
        ] ++
        dev_tally_children() ++
        [
          # Start a worker by calling: Nila.Worker.start_link(arg)
          # {Nila.Worker, arg},
          # Start to serve requests, typically the last entry
          NilaWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Nila.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NilaWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp text_chat_children do
    config =
      Application.get_env(:nila, Nila.Gst.Extraction.Providers.OpenAICompatibleChatFinch, [])

    chat = Application.get_env(:nila, Nila.Gst.Extraction.Providers.OpenAICompatibleChat, [])

    if is_nil(chat[:api_key]) do
      []
    else
      if(config[:start] == false,
        do: [],
        else: [Nila.Gst.Extraction.Providers.OpenAICompatibleChatFinch]
      )
    end
  end

  defp dev_tally_children do
    config = Application.get_env(:nila, :dev_tally_simulator, [])
    if config[:enabled], do: [{Nila.Dev.TallySimulator, config}], else: []
  end
end
