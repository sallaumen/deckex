defmodule DeckexWeb.CardLinksTest do
  @moduledoc """
  Card names are the densest information on every screen, and they were dead
  text: the question a player asks constantly — what does this card do? — had
  no answer anywhere in the app.

  These pin the two halves that matter: a known card links out, and an
  unresolved one stays plain rather than pointing somewhere invented.
  """
  use DeckexWeb.ConnCase, async: true

  import Mox
  import Phoenix.LiveViewTest

  alias Deckex.Cards
  alias Deckex.CatalogueFixture
  alias Deckex.Decks

  setup :verify_on_exit!

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell))

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck dos Links", source: :paste})

    deck
  end

  test "a card the catalogue knows links to its Scryfall page", %{conn: conn} do
    deck = deck()
    sol_ring = Cards.get_by_name("Sol Ring")

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ sol_ring.scryfall_uri
    assert html =~ ~s(rel="noopener noreferrer")
  end

  test "uris_for_names answers only for what it knows" do
    deck()

    uris = Cards.uris_for_names(["Sol Ring", "Carta Que Não Existe"])

    assert uris["Sol Ring"] =~ "scryfall.com"
    refute Map.has_key?(uris, "Carta Que Não Existe")
  end

  test "it matches on the normalized name, not the exact spelling" do
    deck()

    assert Cards.uris_for_names(["SOL RING"])["SOL RING"] =~ "scryfall.com"
  end

  test "one query serves a whole screen" do
    deck()

    # Two hundred names must not become two hundred round trips.
    names = Enum.map(1..200, fn i -> "Carta #{i}" end) ++ ["Sol Ring"]

    assert map_size(Cards.uris_for_names(names)) == 1
  end
end
