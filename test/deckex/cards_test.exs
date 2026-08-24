defmodule Deckex.CardsTest do
  # async: false, and it is the one module that has to be.
  #
  # Everywhere else, cards are written through `Deckex.CatalogueFixture` or
  # `Cards.resolve_names/1`, which both insert in `oracle_id` order — a single
  # global order is what stops two concurrent transactions from taking the same
  # unique-index locks in opposite directions and deadlocking (40P01).
  #
  # These tests cannot honour that order: their whole subject is the catalogue
  # write path, so they hand-pick real card identities ("Sol Ring", "Cultivate")
  # in whatever sequence each scenario needs. A test that inserts Sol Ring and
  # then resolves Cultivate takes its locks in the opposite order from a
  # concurrent seed of both, and one of the two dies. ExUnit runs `async: false`
  # modules after every async one, so serialising here removes the overlap
  # entirely — at a cost of about a tenth of a second.
  use Deckex.DataCase, async: false

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

    # A name lookup answers with one printing, usually the newest, and a
    # printing released this month has no market price. Steam Vents, Breeding
    # Pool and Swiftfoot Boots all arrived here that way and stayed blank in
    # the column the owner buys from.
    test "a card that arrives unpriced is queued for repricing" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [ScryfallFixture.load!("steam_vents")], not_found: []}}
      end)

      assert {:ok, %{cards: [card]}} = Cards.resolve_names(["Steam Vents"])
      assert card.price_usd == nil

      assert_enqueued(worker: Deckex.Workers.RepriceWorker, args: %{card_ids: [card.id]})
    end

    test "a card that arrives priced costs no second request" do
      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:ok, %{found: [ScryfallFixture.load!("sol_ring")], not_found: []}}
      end)

      assert {:ok, %{cards: [_card]}} = Cards.resolve_names(["Sol Ring"])

      refute_enqueued(worker: Deckex.Workers.RepriceWorker)
    end
  end

  describe "reprice/1" do
    test "takes the cheapest printing, not the one the lookup happened to return" do
      card = insert(:card, name: "Cyclonic Rift", price_usd: Decimal.new("39.83"))

      expect(Deckex.Scryfall.Mock, :printings, fn oracle_id ->
        assert oracle_id == card.oracle_id

        {:ok, [printing("83.74"), printing("28.99"), printing("35.06")]}
      end)

      assert {:ok, repriced} = Cards.reprice(card)
      assert Decimal.equal?(repriced.price_usd, Decimal.new("28.99"))
    end

    test "prices a card the catalogue had no price for at all" do
      card = insert(:card, name: "Steam Vents", price_usd: nil)

      expect(Deckex.Scryfall.Mock, :printings, fn _oracle_id ->
        {:ok, [printing(nil), printing("10.67")]}
      end)

      assert {:ok, repriced} = Cards.reprice(card)
      assert Decimal.equal?(repriced.price_usd, Decimal.new("10.67"))
    end

    # Repricing may correct a number, never erase one: the price on screen is
    # what the owner budgets from, and an em dash where there used to be a
    # figure reads as "this card is free".
    test "a card Scryfall cannot price keeps the price it had" do
      card = insert(:card, name: "Sol Ring", price_usd: Decimal.new("1.50"))

      expect(Deckex.Scryfall.Mock, :printings, fn _oracle_id -> {:ok, [printing(nil)]} end)

      assert {:ok, repriced} = Cards.reprice(card)
      assert Decimal.equal?(repriced.price_usd, Decimal.new("1.50"))
    end

    # The cheapest printing is a different Scryfall object from the one this
    # row was built out of. Everything on it except the price belongs to that
    # other printing.
    test "nothing but the price moves" do
      card = insert(:card, name: "Sol Ring", image_art_crop_url: "https://img/original.jpg")

      expect(Deckex.Scryfall.Mock, :printings, fn _oracle_id -> {:ok, [printing("1.00")]} end)

      assert {:ok, repriced} = Cards.reprice(card)
      assert repriced.image_art_crop_url == "https://img/original.jpg"
      assert repriced.scryfall_id == card.scryfall_id
      assert repriced.name == card.name
    end

    test "a Scryfall failure is an error, not a wrong price" do
      card = insert(:card, name: "Sol Ring", price_usd: Decimal.new("1.50"))

      expect(Deckex.Scryfall.Mock, :printings, fn _oracle_id ->
        {:error, Error.new(:scryfall_unavailable, "fora do ar")}
      end)

      assert {:error, %Error{code: :scryfall_unavailable}} = Cards.reprice(card)
    end
  end

  describe "reprice_all/1" do
    test "reports what actually moved" do
      cheap = insert(:card, name: "Arcane Signet", price_usd: Decimal.new("0.44"))
      rift = insert(:card, name: "Cyclonic Rift", price_usd: Decimal.new("39.83"))

      stub(Deckex.Scryfall.Mock, :printings, fn oracle_id ->
        cond do
          oracle_id == cheap.oracle_id -> {:ok, [printing("0.44")]}
          oracle_id == rift.oracle_id -> {:ok, [printing("28.99")]}
        end
      end)

      assert %{checked: 2, changed: [%{name: "Cyclonic Rift", from: from, to: to}]} =
               Cards.reprice_all([cheap, rift])

      assert Decimal.equal?(from, Decimal.new("39.83"))
      assert Decimal.equal?(to, Decimal.new("28.99"))
    end

    # A price is advisory. One 404 must not cost the other hundred and
    # seventy-eight corrections — the first real pass over this catalogue hit
    # exactly one transient failure and finished anyway.
    @tag capture_log: true
    test "one card failing does not stop the pass" do
      broken = insert(:card, name: "Scute Swarm", price_usd: Decimal.new("5.00"))
      fine = insert(:card, name: "Sol Ring", price_usd: Decimal.new("1.50"))

      stub(Deckex.Scryfall.Mock, :printings, fn oracle_id ->
        if oracle_id == broken.oracle_id do
          {:error, Error.new(:scryfall_unavailable, "fora do ar")}
        else
          {:ok, [printing("0.99")]}
        end
      end)

      assert %{checked: 1, changed: [%{name: "Sol Ring"}]} = Cards.reprice_all([broken, fine])
    end
  end

  defp printing(usd), do: %{"prices" => %{"usd" => usd}}

  describe "stale prices" do
    # A price the owner budgets from should say how old it is, and the sweep
    # should touch only what has aged — a full reprice costs one request per
    # card, and prices do not move fast enough to pay that daily.
    test "a price read today is not stale" do
      insert(:card, name: "Fresca", prices_updated_at: DateTime.utc_now(:second))

      assert Cards.stale_prices() == []
    end

    test "a price older than the window is stale" do
      old = DateTime.add(DateTime.utc_now(:second), -(Cards.price_max_age_days() + 1), :day)
      insert(:card, name: "Velha", prices_updated_at: old)

      assert [%{name: "Velha"}] = Cards.stale_prices()
    end

    # Never priced is the oldest price there is, not a row to skip: an unpriced
    # card is exactly the one whose ceiling guard passes everything.
    test "a card that was never priced counts as stale" do
      insert(:card, name: "Sem Preço", price_usd: nil, prices_updated_at: nil)

      assert [%{name: "Sem Preço"}] = Cards.stale_prices()
    end

    test "price_age reports the oldest and the newest read" do
      old = DateTime.add(DateTime.utc_now(:second), -30, :day)
      insert(:card, name: "Velha", prices_updated_at: old)
      insert(:card, name: "Nova", prices_updated_at: DateTime.utc_now(:second))

      %{oldest: oldest, newest: newest} = Cards.price_age()

      assert DateTime.compare(oldest, newest) == :lt
    end

    test "an empty catalogue has no age at all, rather than a date of zero" do
      assert %{oldest: nil, newest: nil} = Cards.price_age()
    end
  end
end
