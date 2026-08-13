defmodule Deckex.ScryfallFixture do
  @moduledoc """
  Loads real Scryfall card responses committed under
  `test/support/fixtures/scryfall/`. Using real payloads rather than
  hand-written maps is deliberate: the shape of a double-faced card is exactly
  the kind of detail a hand-written fixture gets wrong.
  """

  @dir Path.join([__DIR__, "fixtures", "scryfall"])

  @doc ~S"""
  Loads a fixture by basename, e.g. `load!("sol_ring")`.
  """
  @spec load!(String.t()) :: map()
  def load!(name) do
    @dir
    |> Path.join("#{name}.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
