defmodule Deckex.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DeckexWeb.Telemetry,
      Deckex.Repo,
      {Oban, Application.fetch_env!(:deckex, Oban)},
      {DNSCluster, query: Application.get_env(:deckex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Deckex.PubSub},
      # Start a worker by calling: Deckex.Worker.start_link(arg)
      # {Deckex.Worker, arg},
      # Start to serve requests, typically the last entry
      DeckexWeb.Endpoint,
      # The price cron fires at 06:00 — on a desktop the app is often simply
      # not running at 06:00, and the owner opened it to "preços de 13 dias
      # atrás" because the sweep had never had a chance to fire. On boot, one
      # stale-only sweep; uniqueness makes it free when the cron already ran.
      {Task, &Deckex.Cards.reprice_stale_on_boot/0}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Deckex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DeckexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
