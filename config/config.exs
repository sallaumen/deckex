# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :deckex,
  ecto_repos: [Deckex.Repo],
  generators: [timestamp_type: :utc_datetime]

# Repo-wide Ecto defaults: UTC timestamps everywhere + advisory migration lock.
config :deckex, Deckex.Repo,
  migration_timestamps: [type: :utc_datetime],
  migration_lock: :pg_advisory_lock

# Background jobs. `scryfall` is serialized (1) because POST /cards/collection is
# capped at 2 requests/second and the adapter throttles internally — concurrent
# jobs would race that budget and earn a 429.
config :deckex, Oban,
  repo: Deckex.Repo,
  queues: [default: 10, scryfall: 1, ai: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7, interval: :timer.minutes(30)},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30), interval: :timer.minutes(5)}
  ]

# Integration ports (ports & adapters). Tests override these with Mox mocks.
config :deckex, Deckex.Scryfall.Client, adapter: Deckex.Scryfall.Http
config :deckex, Deckex.AI.Client, adapter: Deckex.AI.ClaudeCli
config :deckex, Deckex.Moxfield.Client, adapter: Deckex.Moxfield.Http

# Model for bulk role classification, and how many cards go in one call.
config :deckex, Deckex.AI, model: "sonnet", batch_size: 15

# Configure the endpoint
config :deckex, DeckexWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DeckexWeb.ErrorHTML, json: DeckexWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Deckex.PubSub,
  live_view: [signing_salt: "87nhqA/P"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  deckex: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  deckex: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
