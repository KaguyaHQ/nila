defmodule Nila.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      NilaWeb.Telemetry,
      Nila.Repo,
      {Oban, Application.fetch_env!(:nila, Oban)},
      {DNSCluster, query: Application.get_env(:nila, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Nila.PubSub},
      Nila.Gst.Extraction.MistralFinch,
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
end
