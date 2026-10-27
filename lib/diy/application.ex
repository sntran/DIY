defmodule DIY.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # The database of the short links. The guard runs the migration of
      # their table, and keeps their counts of today (DIY.Links).
      DIY.Repo,
      DIY.Links.Guard,
      {Phoenix.PubSub, name: DIY.PubSub},
      # The data of the public services: the weather and the utility areas.
      DIY.Cache,
      # Start to serve requests, typically the last entry
      DIYWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DIY.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DIYWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
