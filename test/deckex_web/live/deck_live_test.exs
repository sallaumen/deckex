defmodule DeckexWeb.DeckLiveTest do
  use DeckexWeb.ConnCase, async: true

  import Mox
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Decks

  setup :verify_on_exit!

  defp import_deck(text, name \\ "Iroh de Teste") do
    {:ok, deck} = Decks.import_from_text(text, %{name: name, source: :paste})

    deck
  end

  describe "A Mesa" do
    test "greets an empty table without pretending there is a deck", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "A Mesa"
      assert html =~ "Nenhum deck ainda"
    end

    test "lists a deck with its commander and vital sign", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring natures_lore forest))
      import_deck("Commander\n1 Nature's Lore\n----\n1 Sol Ring\n4 Forest", "Deck da Mesa")

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "Deck da Mesa"
      assert html =~ "Nature&#39;s Lore"
      # The vital sign is the point of the tile: it must say something.
      assert html =~ "crítico" or html =~ "aviso" or html =~ "tudo certo"
    end

    test "links each tile to its deck", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring))
      deck = import_deck("1 Sol Ring")

      {:ok, live, _html} = live(conn, ~p"/")

      assert live |> element(~s|a[href="/decks/#{deck.id}"]|) |> has_element?()
    end
  end

  describe "the page hears the deck change under it" do
    setup do
      CatalogueFixture.seed!(~w(sol_ring counterspell forest))

      %{deck: import_deck("1 Sol Ring\n4 Forest")}
    end

    # The regression the owner reported as "os alertas apontam para uma versão
    # antiga": the page only subscribed to consults, so a card added from
    # another tab — or a whole optimization applied from the run page — left
    # the findings frozen at whatever the deck looked like at mount.
    test "a card added elsewhere updates the open page's numbers", %{conn: conn, deck: deck} do
      {:ok, view, html} = live(conn, ~p"/decks/#{deck.id}")

      refute html =~ "Counterspell"

      {:ok, _card} = Decks.add_card(deck, "Counterspell")

      html = render(view)
      assert html =~ "Counterspell"
    end

    test "a deck deleted elsewhere says goodbye instead of crashing", %{conn: conn, deck: deck} do
      {:ok, view, _html} = live(conn, ~p"/decks/#{deck.id}")

      {:ok, _deleted} = Decks.delete_deck(deck)

      flash = assert_redirect(view, "/")
      assert flash["info"] =~ "apagado"
    end
  end

  describe "the deck screen" do
    setup do
      CatalogueFixture.seed!(~w(sol_ring natures_lore command_tower counterspell forest))

      deck =
        import_deck(
          "Commander\n1 Nature's Lore\n----\n1 Sol Ring\n1 Command Tower\n1 Counterspell\n4 Forest"
        )

      %{deck: deck}
    end

    test "shows the deck name and its commander", %{conn: conn, deck: deck} do
      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "Iroh de Teste"
      assert html =~ "Nature&#39;s Lore"
    end

    test "renders the findings the engine produced", %{conn: conn, deck: deck} do
      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "Achados"
      # A seven-card deck cannot pass the interaction lens.
      assert html =~ "interaction."
    end

    test "renders every measured lens", %{conn: conn, deck: deck} do
      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "Curva de mana"
      assert html =~ "Mana e aceleração"
      assert html =~ "Interação"
      assert html =~ "Consistência"
    end

    test "lists the cards", %{conn: conn, deck: deck} do
      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "Sol Ring"
      assert html =~ "Command Tower"
    end

    test "sends an unknown deck back to the table instead of crashing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/decks/#{Ecto.UUID.generate()}")
    end
  end
end
