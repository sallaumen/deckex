defmodule Deckex.Repo do
  @moduledoc """
  The application repo.

  `transact/2` is not defined here: Ecto ships it, with the same semantics the
  playbook asks for — the function returns `{:ok, value}` or `{:error, reason}`
  and a tagged error rolls the transaction back, so it composes with `with`.
  """
  use Ecto.Repo,
    otp_app: :deckex,
    adapter: Ecto.Adapters.Postgres
end
