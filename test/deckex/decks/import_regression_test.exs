defmodule Deckex.Decks.ImportRegressionTest do
  @moduledoc """
  Imports a real 100-card Commander export end to end and locks in the counts.
  If the parser, the resolver or the persistence layer drifts, this test says so.
  """
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards
  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Decks
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  @decklist "test/support/fixtures/decklists/iroh_das_lontra.txt"

  # The catalogue holds only the cards we have fixtures for; the rest come back
  # from the (mocked) port as not_found, which the import records instead of
  # failing on.
  defp seed_catalogue do
    # Every one of these is genuinely in the decklist — seeding a card the deck
    # does not contain would silently weaken the count assertions below.
    for name <- ~w(sol_ring natures_lore command_tower counterspell forest) do
      attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

      %Card{} |> Card.changeset(attrs) |> Repo.insert!()
    end
  end

  defp import_real_deck do
    expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      # Everything not seeded is reported unresolved rather than invented.
      {:ok, %{found: [], not_found: names}}
    end)

    Decks.import_from_text(File.read!(@decklist), %{name: "Iroh das Lontra", source: :paste})
  end

  test "imports the deck, keeping quantities, boards and unresolved names" do
    seed_catalogue()

    assert {:ok, deck} = import_real_deck()

    cards = Decks.list_deck_cards(deck)
    by_name = Map.new(cards, &{&1.card.name, &1})

    # Iroh is not in the seeded catalogue, so the commander line resolves to
    # nothing and no card lands on the commander board. That is the point of
    # the last_error assertion below: the card is reported, not swallowed.
    refute Enum.any?(cards, &(&1.board == :commander))
    assert deck.color_identity == []

    # Quantities survive: the decklist has 4 Forest.
    assert %{quantity: 4, board: :main} = by_name["Forest"]
    assert %{quantity: 1, board: :main} = by_name["Sol Ring"]

    # Only the seeded cards made it in; the rest are reported.
    assert length(cards) == 5

    # Unresolved names are recorded, not swallowed.
    assert deck.last_error =~ "Iroh, Grand Lotus"

    # The raw text is kept for a future re-import.
    assert deck.raw_decklist == File.read!(@decklist)
  end

  test "the seeded cards come out classified by the rules" do
    seed_catalogue()

    assert {:ok, _deck} = import_real_deck()

    assert [%{kind: :ramp, source: :rule}] = Cards.roles_for(Cards.get_by_name("Sol Ring"))
    assert [%{kind: :counter, source: :rule}] = Cards.roles_for(Cards.get_by_name("Counterspell"))

    assert "Nature's Lore"
           |> Cards.get_by_name()
           |> Cards.roles_for()
           |> Enum.map(& &1.kind)
           |> Enum.sort() == [:fixing, :ramp]
  end

  test "a deck whose cards the rules all cover comes out ready" do
    seed_catalogue()

    assert {:ok, deck} = import_real_deck()
    assert deck.status == :ready
  end
end
