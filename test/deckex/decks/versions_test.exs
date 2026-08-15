defmodule Deckex.Decks.VersionsTest do
  use Deckex.DataCase, async: true

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Decks.DeckVersion
  alias Deckex.Decks.Versions

  defp deck(text \\ "Commander:\n1 Nature's Lore\n\nDeck:\n1 Sol Ring\n4 Forest") do
    CatalogueFixture.seed!(~w(sol_ring forest natures_lore cultivate counterspell))

    {:ok, deck} = Decks.import_from_text(text, %{name: "Deck Versionado", source: :paste})

    deck
  end

  describe "the version an import leaves behind" do
    # Without it the history starts at whatever the owner happened to do next,
    # and "what did the import look like" is unanswerable a week later.
    test "v1 is the deck as it arrived" do
      deck = deck()

      assert [%DeckVersion{number: 1, origin: :import} = version] = Versions.list(deck)
      assert version.commanders == ["Nature's Lore"]
      assert DeckVersion.size(version) == 6
      # Nothing came before it, so it changed nothing.
      assert DeckVersion.applied(version) == []
    end
  end

  describe "mark/2" do
    test "numbers run forward, one per deck" do
      deck = deck()

      {:ok, _v2} = Versions.mark(deck)
      {:ok, v3} = Versions.mark(deck)

      assert v3.number == 3
      assert Enum.map(Versions.list(deck), & &1.number) == [3, 2, 1]
    end

    test "a version records what it did to the one before it" do
      deck = deck()
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")
      {:ok, _} = Decks.add_card(deck, "Cultivate")

      {:ok, version} = Versions.mark(deck, label: "Trocando Sol Ring")

      assert Enum.map(DeckVersion.applied(version), &{&1["action"], &1["card"]}) == [
               {"add", "Cultivate"},
               {"cut", "Sol Ring"}
             ]
    end

    test "the optimizer's own changelog is taken as given" do
      deck = deck()
      changes = %{"applied" => [%{"action" => "add", "card" => "Cultivate", "reason" => "mana"}]}

      {:ok, version} =
        Versions.mark(deck, origin: :optimization, changes: changes, label: "Rodada de 15/08")

      assert version.origin == :optimization
      assert [%{"reason" => "mana"}] = DeckVersion.applied(version)
    end
  end

  describe "drifted?/1" do
    # So that "I never saved this" is something the screen says rather than
    # something the owner finds out.
    test "a freshly marked version has not drifted" do
      deck = deck()

      refute Versions.drifted?(deck)
    end

    test "an edit moves the working state away from the last version" do
      deck = deck()
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")

      assert Versions.drifted?(deck)
    end

    # Two lists holding the same cards in a different order are the same list.
    test "reordering is not drift" do
      deck = deck()
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")
      {:ok, _} = Decks.add_card(deck, "Sol Ring")

      refute Versions.drifted?(deck)
    end
  end

  describe "restore/2" do
    test "puts the cards back exactly as the version held them" do
      deck = deck()
      {:ok, v1} = Versions.fetch(deck, 1)

      {:ok, _} = Decks.remove_card(deck, "Sol Ring")
      {:ok, _} = Decks.add_card(deck, "Counterspell")

      {:ok, restored} = Versions.restore(deck, v1)

      names = restored |> Decks.list_deck_cards() |> Enum.map(& &1.card.name) |> Enum.sort()
      assert names == ["Forest", "Nature's Lore", "Sol Ring"]
    end

    test "the commander comes back as a commander" do
      deck = deck()
      {:ok, v1} = Versions.fetch(deck, 1)
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")

      {:ok, restored} = Versions.restore(deck, v1)

      assert [%{card: %{name: "Nature's Lore"}}] =
               restored |> Decks.list_deck_cards() |> Enum.filter(&(&1.board == :commander))
    end

    test "quantities survive the round trip" do
      deck = deck()
      {:ok, v1} = Versions.fetch(deck, 1)
      {:ok, _} = Decks.remove_card(deck, "Forest")

      {:ok, restored} = Versions.restore(deck, v1)

      forest = restored |> Decks.list_deck_cards() |> Enum.find(&(&1.card.name == "Forest"))
      assert forest.quantity == 4
    end

    # History is a record of what happened, not a tree to prune.
    test "going back leaves the versions after it where they are" do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Cultivate")
      {:ok, _v2} = Versions.mark(deck)
      {:ok, v1} = Versions.fetch(deck, 1)

      {:ok, _restored} = Versions.restore(deck, v1)

      assert Enum.map(Versions.list(deck), & &1.number) == [2, 1]
    end

    test "the next version marked after going back is the next number" do
      deck = deck()
      {:ok, _v2} = Versions.mark(deck)
      {:ok, v1} = Versions.fetch(deck, 1)
      {:ok, _restored} = Versions.restore(deck, v1)

      {:ok, v3} = Versions.mark(deck)

      assert v3.number == 3
    end
  end

  describe "diff/2 — what to buy to get from one to the other" do
    setup do
      deck = deck()
      {:ok, v1} = Versions.fetch(deck, 1)

      {:ok, _} = Decks.remove_card(deck, "Sol Ring")
      {:ok, _} = Decks.add_card(deck, "Cultivate")
      {:ok, _} = Decks.add_card(deck, "Counterspell")
      {:ok, v2} = Versions.mark(deck)

      %{deck: deck, v1: v1, v2: v2}
    end

    test "names the cards the target has and the source does not", %{v1: v1, v2: v2} do
      diff = Versions.diff(v1, v2)

      assert Enum.map(diff.buy, & &1.name) == ["Counterspell", "Cultivate"]
      assert Enum.map(diff.drop, & &1.name) == ["Sol Ring"]
    end

    test "the total is what the buying costs, and cuts are not refunds", %{v1: v1, v2: v2} do
      diff = Versions.diff(v1, v2)

      assert Decimal.gt?(diff.total_usd, Decimal.new(0))
      assert diff.unpriced == 0
    end

    test "read the other way it is the opposite list", %{v1: v1, v2: v2} do
      diff = Versions.diff(v2, v1)

      assert Enum.map(diff.buy, & &1.name) == ["Sol Ring"]
      assert Enum.map(diff.drop, & &1.name) == ["Counterspell", "Cultivate"]
    end

    test "a version compared with itself asks for nothing", %{v1: v1} do
      assert %{buy: [], drop: []} = Versions.diff(v1, v1)
    end

    test "the buy list comes out as text a shop can read", %{v1: v1, v2: v2} do
      text = v1 |> Versions.diff(v2) |> Versions.buy_text()

      assert text == "1 Counterspell\n1 Cultivate\n"
    end

    # A version that swapped the commander has to say so, and the new commander
    # is a card the owner may well have to buy.
    test "a commander swap shows up as a card to buy", %{v1: v1} do
      swapped = %{v1 | commanders: ["Cultivate"]}

      diff = Versions.diff(v1, swapped)

      assert Enum.map(diff.buy, & &1.name) == ["Cultivate"]
      assert Enum.map(diff.drop, & &1.name) == ["Nature's Lore"]
    end
  end
end
