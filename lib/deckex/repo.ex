defmodule Deckex.Repo do
  use Ecto.Repo,
    otp_app: :deckex,
    adapter: Ecto.Adapters.Postgres
end
