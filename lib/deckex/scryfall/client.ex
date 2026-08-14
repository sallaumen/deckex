defmodule Deckex.Scryfall.Client do
  @moduledoc """
  Port for the Scryfall API. The real adapter is `Deckex.Scryfall.Http`; tests
  use `Deckex.Scryfall.Mock`. Callers go through the `Deckex.Scryfall` facade
  rather than naming an adapter directly.
  """

  @doc """
  Resolves card names to Scryfall card objects.

  Returns the raw objects that resolved plus the names that did not, so the
  caller can report unresolved cards by name instead of silently dropping them.
  """
  @callback fetch_by_names([String.t()]) ::
              {:ok, %{found: [map()], not_found: [String.t()]}}
              | {:error, Deckex.Error.t()}

  @doc """
  Every card matching a Scryfall search query.

  Used for one thing today: `is:gamechanger`, the Commander Format Panel's
  Game Changers list. That list is revised a few times a year, so it is asked
  for rather than written down.
  """
  @callback search(String.t()) :: {:ok, [map()]} | {:error, Deckex.Error.t()}
end
