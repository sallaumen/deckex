defmodule Deckex.CardsTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards
  alias Deckex.Cards.Card
  alias Deckex.Error
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  describe "resolve_names/1" do
    test "returns an empty result for an empty list without calling Scryfall" do
      assert {:ok, %{cards: [], not_found: []}} = Cards.resolve_names([])
    end

    test "reads a known card from the database without calling Scryfall" do
      card = insert(:card, name: "Sol Ring", name_normalized: "sol ring")

      assert {:ok, %{cards: [found], not_found: []}} = Cards.resolve_names(["Sol Ring"])
      assert found.id == card.id
    end

    test "matches a known card regardless of how the name is written" do
      insert(:card, name: "Cultivate", name_normalized: "cultivate")

      assert {:ok, %{cards: [_card], not_found: []}} =
               Cards.resolve_names(["Cultivate (M21) 177"])
    end

    test "fetches an unknown card from Scryfall and stores it" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn ["Sol Ring"] ->
        {:ok, %{found: [ScryfallFixture.load!("sol_ring")], not_found: []}}
      end)

      assert {:ok, %{cards: [card], not_found: []}} = Cards.resolve_names(["Sol Ring"])
      assert card.name == "Sol Ring"
      assert card.produced_mana == ["C"]

      # Now cached: a second call must not hit the port again. verify_on_exit!
      # fails the test if the mock is called a second time.
      assert {:ok, %{cards: [_cached]}} = Cards.resolve_names(["Sol Ring"])
    end

    test "asks Scryfall only for the names it does not already have" do
      insert(:card, name: "Sol Ring", name_normalized: "sol ring")

      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
        assert names == ["Cultivate"]
        {:ok, %{found: [ScryfallFixture.load!("cultivate")], not_found: []}}
      end)

      assert {:ok, %{cards: cards, not_found: []}} =
               Cards.resolve_names(["Sol Ring", "Cultivate"])

      assert length(cards) == 2
    end

    test "asks Scryfall for the card's real name, not the raw decklist line" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
        # Not "Cultivate (M21) 177" — the API would resolve nothing.
        assert names == ["Cultivate"]
        {:ok, %{found: [ScryfallFixture.load!("cultivate")], not_found: []}}
      end)

      assert {:ok, %{cards: [card]}} = Cards.resolve_names(["Cultivate (M21) 177"])
      assert card.name == "Cultivate"
    end

    test "asks Scryfall for the front face of a Moxfield double-faced line" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
        assert names == ["Agadeem's Awakening"]
        {:ok, %{found: [ScryfallFixture.load!("agadeems_awakening")], not_found: []}}
      end)

      assert {:ok, %{cards: [card]}} =
               Cards.resolve_names([
                 "Agadeem's Awakening / Agadeem, the Undercrypt (ZNR) 90"
               ])

      assert card.mana_cost == "{X}{B}{B}{B}"
    end

    test "reports names Scryfall could not resolve instead of dropping them" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [], not_found: ["Not A Real Card"]}}
      end)

      assert {:ok, %{cards: [], not_found: ["Not A Real Card"]}} =
               Cards.resolve_names(["Not A Real Card"])
    end

    test "deduplicates repeated names before calling the port" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
        assert names == ["Sol Ring"]
        {:ok, %{found: [ScryfallFixture.load!("sol_ring")], not_found: []}}
      end)

      assert {:ok, %{cards: [_single]}} = Cards.resolve_names(["Sol Ring", "Sol Ring"])
    end

    test "stores a double-faced card with the front face's cost" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [ScryfallFixture.load!("agadeems_awakening")], not_found: []}}
      end)

      assert {:ok, %{cards: [card]}} = Cards.resolve_names(["Agadeem's Awakening"])
      assert card.mana_cost == "{X}{B}{B}{B}"
      assert card.type_line == "Sorcery // Land"
    end

    test "upserts instead of duplicating when the oracle_id already exists" do
      fixture = ScryfallFixture.load!("sol_ring")

      # Same card, stored under a stale normalized name: the name lookup misses,
      # so we go to the port and then collide on oracle_id on the way in.
      insert(:card,
        oracle_id: fixture["oracle_id"],
        name: "Sol Ring (stale)",
        name_normalized: "sol ring stale",
        price_usd: nil
      )

      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn ["Sol Ring"] ->
        {:ok, %{found: [fixture], not_found: []}}
      end)

      assert {:ok, %{cards: [card], not_found: []}} = Cards.resolve_names(["Sol Ring"])

      assert card.oracle_id == fixture["oracle_id"]
      # The upsert refreshed the advisory price rather than creating a second row.
      assert card.price_usd != nil
      assert Repo.aggregate(Card, :count) == 1
    end

    test "propagates a Scryfall failure as a domain error" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:error, Error.new(:scryfall_unavailable, "fora do ar")}
      end)

      assert {:error, %Error{code: :scryfall_unavailable}} = Cards.resolve_names(["Sol Ring"])
    end
  end
end
