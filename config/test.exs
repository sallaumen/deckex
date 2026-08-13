import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :deckex, Deckex.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  # Host port 5435 — 5432/5433/5434 belong to other projects on this machine.
  port: 5435,
  database: "deckex_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :deckex, DeckexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "7SQB2m43L7zPE5FvgHyn32ywqlLQbS48uIp6j9FT+pNW05Zb0AsaslF0wd3zi3g3",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Oban: don't run jobs automatically in tests — drive them with perform_job/2.
config :deckex, Oban, testing: :manual

# Integration ports → Mox mocks (see test/support/mocks.ex).
config :deckex, Deckex.Scryfall.Client, adapter: Deckex.Scryfall.Mock

# When the real adapter is exercised directly (test/deckex/scryfall/http_test.exs)
# it routes through Req.Test instead of the network, and does not really sleep.
config :deckex, Deckex.Scryfall.Http,
  req_options: [plug: {Req.Test, Deckex.Scryfall.Http}],
  throttle_ms: 0

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
