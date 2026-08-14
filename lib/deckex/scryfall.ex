defmodule Deckex.Scryfall do
  @moduledoc """
  Facade for the Scryfall port. Resolves the configured adapter once at compile
  time so the domain never names a concrete implementation.
  """
  @behaviour Deckex.Scryfall.Client

  @adapter Application.compile_env(
             :deckex,
             [Deckex.Scryfall.Client, :adapter],
             Deckex.Scryfall.Http
           )

  @impl Deckex.Scryfall.Client
  defdelegate fetch_by_names(names), to: @adapter

  @impl Deckex.Scryfall.Client
  defdelegate search(query), to: @adapter
end
