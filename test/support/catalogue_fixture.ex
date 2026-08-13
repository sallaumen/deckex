defmodule Deckex.CatalogueFixture do
  @moduledoc """
  Seeds the card catalogue from the committed Scryfall fixtures.

  **Insertion is ordered by `oracle_id`, and that is load-bearing.** The Ecto
  sandbox isolates what a test can *see*, not the locks it *takes*: two async
  tests inserting the same card rows in different orders deadlock in Postgres,
  which surfaces as a random `40P01` in whichever test lost. A single global
  order means concurrent seeds queue instead of colliding.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Repo
  alias Deckex.ScryfallFixture

  @dir "test/support/fixtures/scryfall"

  @doc "Seeds the named fixtures, e.g. `seed!(~w(sol_ring cultivate))`."
  @spec seed!([String.t()]) :: [Card.t()]
  def seed!(names) do
    names
    |> Enum.map(&ScryfallFixture.load!/1)
    |> insert_all()
  end

  @doc "Seeds every committed fixture — the whole catalogue a test can know about."
  @spec seed_all!() :: [Card.t()]
  def seed_all! do
    @dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(&(@dir |> Path.join(&1) |> File.read!() |> Jason.decode!()))
    |> insert_all()
  end

  defp insert_all(scryfall_cards) do
    scryfall_cards
    |> Enum.map(&ScryfallMapper.to_attrs/1)
    |> Enum.sort_by(& &1.oracle_id)
    |> Enum.map(fn attrs ->
      %Card{}
      |> Card.changeset(attrs)
      |> Repo.insert!(on_conflict: :nothing, conflict_target: :oracle_id)
    end)
  end
end
