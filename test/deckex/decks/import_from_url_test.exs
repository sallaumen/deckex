defmodule Deckex.Decks.ImportFromUrlTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Error
  alias Deckex.ScryfallFixture
  alias Deckex.Workers.ImportDeckWorker

  setup :verify_on_exit!

  describe "import_from_url/1" do
    test "fetches the deck and imports it" do
      CatalogueFixture.seed!(["sol_ring"])

      expect(Deckex.Moxfield.Mock, :fetch_deck, fn "kq9g4t81" ->
        {:ok, %{name: "Iroh das Lontra", decklist: "1 Sol Ring"}}
      end)

      assert {:ok, deck} = Decks.import_from_url("https://moxfield.com/decks/kq9g4t81")

      assert deck.name == "Iroh das Lontra"
      assert deck.source == :moxfield
      assert deck.moxfield_public_id == "kq9g4t81"
      assert deck.moxfield_url == "https://moxfield.com/decks/kq9g4t81"
      assert deck.last_synced_at != nil
    end

    test "surfaces a Cloudflare block so the UI can offer the paste form" do
      expect(Deckex.Moxfield.Mock, :fetch_deck, fn _id ->
        {:error, Error.new(:moxfield_blocked, "O Moxfield bloqueou a busca. Cola a lista aqui.")}
      end)

      assert {:error, %Error{code: :moxfield_blocked}} =
               Decks.import_from_url("https://moxfield.com/decks/kq9g4t81")
    end

    test "rejects a URL that is not a Moxfield deck without calling out" do
      # verify_on_exit! fails the test if the port is called.
      assert {:error, %Error{code: :moxfield_not_found}} =
               Decks.import_from_url("https://example.com/oi")
    end
  end

  describe "Deckex.Events" do
    test "a subscriber hears when a deck's status changes" do
      CatalogueFixture.seed!(["sol_ring"])

      expect(Deckex.Moxfield.Mock, :fetch_deck, fn _id ->
        {:ok, %{name: "Com evento", decklist: "1 Sol Ring"}}
      end)

      {:ok, deck} = Decks.import_from_url("https://moxfield.com/decks/abc123")

      Deckex.Events.subscribe_deck(deck.id)
      Deckex.Events.broadcast_deck_updated(deck)

      assert_receive {:deck_updated, deck_id}
      assert deck_id == deck.id
    end
  end

  describe "ImportDeckWorker" do
    test "imports the deck at the given URL" do
      CatalogueFixture.seed!(["sol_ring"])

      expect(Deckex.Moxfield.Mock, :fetch_deck, fn _id ->
        {:ok, %{name: "Do worker", decklist: "1 Sol Ring"}}
      end)

      assert :ok = perform_job(ImportDeckWorker, %{url: "https://moxfield.com/decks/abc123"})
      assert [%{name: "Do worker"}] = Decks.list_decks()
    end

    test "cancels rather than retrying when Moxfield blocks" do
      expect(Deckex.Moxfield.Mock, :fetch_deck, fn _id ->
        {:error, Error.new(:moxfield_blocked, "bloqueado")}
      end)

      assert {:cancel, _reason} =
               perform_job(ImportDeckWorker, %{url: "https://moxfield.com/decks/abc123"})
    end

    test "retries a transient failure rather than cancelling" do
      expect(Deckex.Moxfield.Mock, :fetch_deck, fn _id ->
        {:ok, %{name: "T", decklist: "1 Sol Ring"}}
      end)

      expect(Deckex.Scryfall.Mock, :fetch_by_names, fn _names ->
        {:error, Error.new(:scryfall_unavailable, "fora do ar")}
      end)

      assert {:error, %Error{code: :scryfall_unavailable}} =
               perform_job(ImportDeckWorker, %{url: "https://moxfield.com/decks/abc123"})
    end
  end
end
