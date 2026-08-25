defmodule Deckex.Spellbook.Client do
  @moduledoc """
  Port for the Commander Spellbook API. The real adapter is
  `Deckex.Spellbook.Http`; tests use `Deckex.Spellbook.Mock`. Callers go
  through the `Deckex.Spellbook` facade rather than naming an adapter directly.
  """

  @doc """
  Which known combos a decklist assembles, and which it nearly assembles.

  `included` are combos every piece of which is already in the list.
  `almost` are combos missing exactly one card — the more useful half for a
  deck being optimised, because each one names a single card that turns a pile
  of good cards into a line.
  """
  @callback find_combos([String.t()], [String.t()]) ::
              {:ok, %{included: [map()], almost: [map()]}} | {:error, Deckex.Error.t()}
end
