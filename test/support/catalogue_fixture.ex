defmodule Deckex.CatalogueFixture do
  @moduledoc """
  Seeds the card catalogue from the committed Scryfall fixtures.

  **A card row is written at most once per transaction, and that is what keeps
  the suite off the `40P01` that kept coming back.** Rows this transaction has
  already written are visible to it, so `insert_all/1` reads first and inserts
  only what is genuinely new. Seeding twice, or seeding from a LiveView process
  that shares its test's sandbox connection, is therefore free.

  The deadlock this prevents is not a lock-ordering bug, which is why ordering
  never fixed it: the losing transaction had inserted exactly **one** row, so
  there was no order to get wrong. The cycle needs a second write of the same
  row. B writes row R and its speculative insertion completes, leaving an
  uncommitted tuple. A writes R and its speculative insertion is still in
  flight, holding a token. B writes R **again**, meets A's speculative tuple,
  and waits on A's token. A reaches `cards_name_normalized_index`, meets B's
  uncommitted tuple, and waits on B's transaction. Neither moves.

  Inserting the same row **once** from each of two transactions does not
  deadlock — verified against Postgres 16 with 640 concurrent attempts — which
  is the ordinary sandbox case and must keep working.

  Insertion stays ordered by `oracle_id`. That order is still right for the
  multi-row case and costs nothing; it simply was never the cure.

  `Deckex.Cards.CatalogueSeedConcurrencyTest` reproduces the deadlock and
  guards the fix.
  """

  import Ecto.Query, only: [from: 2]

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

  @doc """
  Seeds the named fixtures and returns them keyed by fixture name.

  For tests that need to name the cards they seeded — `seed!/1` returns them in
  `oracle_id` order, which is the point of it and useless for picking one out.

      %{"sol_ring" => sol_ring} = CatalogueFixture.seed_map!(~w(sol_ring cultivate))
  """
  @spec seed_map!([String.t()]) :: %{String.t() => Card.t()}
  def seed_map!(names) do
    by_oracle = Map.new(seed!(names), &{&1.oracle_id, &1})

    Map.new(names, fn name ->
      {name, Map.fetch!(by_oracle, ScryfallFixture.load!(name)["oracle_id"])}
    end)
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
    attrs = scryfall_cards |> Enum.map(&ScryfallMapper.to_attrs/1) |> Enum.sort_by(& &1.oracle_id)

    # The read that makes a second seed free. Rows another, uncommitted
    # transaction wrote stay invisible here — and must, because inserting the
    # same row once from each transaction is the ordinary sandbox case.
    already = Repo.all(from c in Card, where: c.oracle_id in ^Enum.map(attrs, & &1.oracle_id))
    seen = MapSet.new(already, & &1.oracle_id)

    fresh =
      attrs
      |> Enum.reject(&MapSet.member?(seen, &1.oracle_id))
      |> Enum.map(&insert_one!/1)

    Enum.sort_by(already ++ fresh, & &1.oracle_id)
  end

  defp insert_one!(attrs) do
    %Card{}
    |> Card.changeset(attrs)
    |> Repo.insert!(on_conflict: :nothing, conflict_target: :oracle_id, timeout: 60_000)
  end
end
