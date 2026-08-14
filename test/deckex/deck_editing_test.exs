defmodule Deckex.DeckEditingTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Analysis
  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Error

  setup :verify_on_exit!

  # Seed once per test: two seed!/1 calls in one transaction take their locks in
  # two separately-ordered batches, which is how async tests deadlock.
  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell cultivate))

    {:ok, deck} = Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "T", source: :paste})

    deck
  end

  describe "add_card/3" do
    test "adds a card the catalogue already knows" do
      deck = deck()

      assert {:ok, _deck_card} = Decks.add_card(deck, "Counterspell")
      assert "Counterspell" in Enum.map(Decks.list_deck_cards(deck), & &1.card.name)
    end

    test "resolves a card the catalogue does not know" do
      deck = deck()

      assert {:ok, _deck_card} = Decks.add_card(deck, "Cultivate")
      assert "Cultivate" in Enum.map(Decks.list_deck_cards(deck), & &1.card.name)
    end

    test "bumps the quantity of a basic land, which may repeat" do
      deck = deck()

      assert {:ok, _deck_card} = Decks.add_card(deck, "Forest")

      forest = Enum.find(Decks.list_deck_cards(deck), &(&1.card.name == "Forest"))
      assert forest.quantity == 5
    end

    # A model that names the same card in two rows would otherwise build an
    # illegal decklist one click at a time.
    test "refuses a second copy of a singleton card, and says why" do
      deck = deck()
      {:ok, _deck_card} = Decks.add_card(deck, "Counterspell")

      assert {:error, %Error{code: :not_commander_legal, message: message}} =
               Decks.add_card(deck, "Counterspell")

      assert message =~ "uma cópia"

      counterspell = Enum.find(Decks.list_deck_cards(deck), &(&1.card.name == "Counterspell"))
      assert counterspell.quantity == 1
    end

    test "refuses a card that does not exist" do
      deck = deck()

      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [], not_found: ["Carta Inventada"]}}
      end)

      assert {:error, %Error{code: :cards_not_found}} = Decks.add_card(deck, "Carta Inventada")
    end
  end

  describe "remove_card/2" do
    test "drops one copy, leaving the rest" do
      deck = deck()

      assert {:ok, :removed} = Decks.remove_card(deck, "Forest")

      forest = Enum.find(Decks.list_deck_cards(deck), &(&1.card.name == "Forest"))
      assert forest.quantity == 3
    end

    test "deletes the row when the last copy goes" do
      deck = deck()

      assert {:ok, :removed} = Decks.remove_card(deck, "Sol Ring")
      refute "Sol Ring" in Enum.map(Decks.list_deck_cards(deck), & &1.card.name)
    end

    test "refuses to remove a card the deck does not have" do
      assert {:error, %Error{code: :cards_not_found}} = Decks.remove_card(deck(), "Cultivate")
    end
  end

  describe "the analysis sees the edit" do
    test "adding a card changes the next report" do
      deck = deck()

      before = deck |> Decks.snapshot() |> Analysis.report()
      {:ok, _deck_card} = Decks.add_card(deck, "Counterspell")
      later = deck |> Decks.snapshot() |> Analysis.report()

      assert later.interaction.counters == before.interaction.counters + 1
    end
  end

  describe "the dossier" do
    @dossier %{
      "plano" => "Spellslinger.",
      "sinergias" => "Flashback nas Lessons.",
      "linhas_de_vitoria" => "Tesouros do Storm Kiln.",
      "fraquezas" => "Cemitério é tudo."
    }

    test "put_dossier/2 stores the scout's reading and stamps it" do
      deck = deck()

      assert {:ok, updated} = Decks.put_dossier(deck, @dossier)

      assert updated.dossier["plano"] == "Spellslinger."
      assert updated.dossier_source == :scout
      assert updated.dossier_stale == false
      assert updated.dossier_updated_at != nil
    end

    test "edit_dossier/2 marks the text as the owner's and clears staleness" do
      {:ok, deck} = deck() |> Decks.put_dossier(@dossier)
      # add_card returns the DeckCard, not the deck — do not rebind `deck`.
      {:ok, _card} = Decks.add_card(deck, "Counterspell")
      {:ok, stale} = Decks.fetch_deck(deck.id)
      assert stale.dossier_stale

      assert {:ok, edited} = Decks.edit_dossier(stale, %{@dossier | "plano" => "Meu plano."})

      assert edited.dossier["plano"] == "Meu plano."
      assert edited.dossier_source == :manual
      assert edited.dossier_stale == false
    end

    test "adding a card marks an existing dossier stale" do
      {:ok, deck} = deck() |> Decks.put_dossier(@dossier)

      {:ok, _card} = Decks.add_card(deck, "Counterspell")

      {:ok, fresh} = Decks.fetch_deck(deck.id)
      assert fresh.dossier_stale
    end

    test "removing a card marks an existing dossier stale" do
      {:ok, deck} = deck() |> Decks.put_dossier(@dossier)

      {:ok, :removed} = Decks.remove_card(deck, "Sol Ring")

      {:ok, fresh} = Decks.fetch_deck(deck.id)
      assert fresh.dossier_stale
    end

    test "editing a deck with no dossier does not invent a stale flag" do
      deck = deck()

      {:ok, _card} = Decks.add_card(deck, "Counterspell")

      {:ok, fresh} = Decks.fetch_deck(deck.id)
      refute fresh.dossier_stale
    end
  end
end
