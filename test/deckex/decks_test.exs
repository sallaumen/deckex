defmodule Deckex.DecksTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  # Seed the catalogue so imports need no Scryfall call at all.
  defp seed_catalogue(names) do
    for name <- names do
      attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

      %Card{} |> Card.changeset(attrs) |> Repo.insert!()
    end
  end

  describe "import_from_text/2" do
    test "creates a deck with its cards" do
      seed_catalogue(["sol_ring", "cultivate"])

      text = "1 Sol Ring\n1 Cultivate"

      assert {:ok, deck} = Decks.import_from_text(text, %{name: "Teste", source: :paste})
      assert deck.name == "Teste"
      assert deck.source == :paste

      cards = Decks.list_deck_cards(deck)
      assert cards |> Enum.map(& &1.card.name) |> Enum.sort() == ["Cultivate", "Sol Ring"]
    end

    test "keeps the quantity of each line" do
      seed_catalogue(["forest"])

      assert {:ok, deck} = Decks.import_from_text("4 Forest", %{name: "T", source: :paste})
      assert [%{quantity: 4}] = Decks.list_deck_cards(deck)
    end

    test "stores the raw decklist so the deck can be rebuilt later" do
      seed_catalogue(["sol_ring"])
      text = "1 Sol Ring"

      assert {:ok, deck} = Decks.import_from_text(text, %{name: "T", source: :paste})
      assert deck.raw_decklist == text
    end

    test "puts the commander on the commander board" do
      seed_catalogue(["sol_ring", "cultivate"])

      text = """
      Commander
      1 Cultivate
       ----
      1 Sol Ring
      """

      assert {:ok, deck} = Decks.import_from_text(text, %{name: "T", source: :paste})

      boards = Map.new(Decks.list_deck_cards(deck), &{&1.card.name, &1.board})
      assert boards == %{"Cultivate" => :commander, "Sol Ring" => :main}
    end

    test "derives colour identity from the commander" do
      seed_catalogue(["cultivate"])

      assert {:ok, deck} =
               Decks.import_from_text("Commander\n1 Cultivate", %{name: "T", source: :paste})

      assert deck.color_identity == ["G"]
    end

    test "leaves colour identity empty when no commander was declared" do
      seed_catalogue(["sol_ring"])

      assert {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})
      assert deck.color_identity == []
    end

    test "resolves cards missing from the catalogue through Scryfall" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn ["Sol Ring"] ->
        {:ok, %{found: [ScryfallFixture.load!("sol_ring")], not_found: []}}
      end)

      assert {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})
      assert [%{card: %{name: "Sol Ring"}}] = Decks.list_deck_cards(deck)
    end

    test "records unresolved names on the deck instead of failing the import" do
      seed_catalogue(["sol_ring"])

      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [], not_found: ["Carta Inventada"]}}
      end)

      text = "1 Sol Ring\n1 Carta Inventada"

      assert {:ok, deck} = Decks.import_from_text(text, %{name: "T", source: :paste})
      assert deck.last_error =~ "Carta Inventada"
      assert length(Decks.list_deck_cards(deck)) == 1
    end

    test "rejects a decklist with no cards" do
      assert {:error, %Error{code: :empty_decklist}} =
               Decks.import_from_text("conversa fiada", %{name: "T", source: :paste})
    end

    test "propagates a Scryfall failure" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:error, Error.new(:scryfall_unavailable, "fora do ar")}
      end)

      assert {:error, %Error{code: :scryfall_unavailable}} =
               Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})
    end

    test "leaves the deck ready when every card is already classified" do
      seed_catalogue(["sol_ring"])

      assert {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})
      assert deck.status == :ready
    end

    test "marks the deck classifying and enqueues the residue" do
      seed_catalogue(["young_pyromancer"])

      assert {:ok, deck} =
               Decks.import_from_text("1 Young Pyromancer", %{name: "T", source: :paste})

      assert deck.status == :classifying
      assert_enqueued(worker: Deckex.Workers.ClassifyCardsWorker)
    end
  end

  describe "archive_deck/1" do
    test "hides a deck from the list without deleting it" do
      seed_catalogue(["sol_ring"])
      {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})

      assert {:ok, archived} = Decks.archive_deck(deck)
      assert archived.archived_at != nil
      assert Decks.list_decks() == []
    end
  end
end
