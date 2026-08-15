defmodule DeckexWeb.DeckActionsTest do
  use DeckexWeb.ConnCase, async: true

  import Deckex.Factory
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Decks

  defp deck(name \\ "Nome do Import") do
    CatalogueFixture.seed!(~w(sol_ring natures_lore forest))

    {:ok, deck} =
      Decks.import_from_text("Commander:\n1 Nature's Lore\n\nDeck:\n1 Sol Ring\n4 Forest", %{
        name: name,
        source: :paste
      })

    deck
  end

  describe "renaming" do
    test "the name is the owner's, not the import's", %{conn: conn} do
      deck = deck()

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live |> element("button[phx-click='start-rename']") |> render_click()

      html =
        live
        |> form("form[phx-submit='rename']", deck: %{name: "Iroh das Lontra"})
        |> render_submit()

      assert html =~ "Iroh das Lontra"
      assert Decks.get_deck(deck.id).name == "Iroh das Lontra"
    end

    test "blank is refused — a nameless deck is unfindable", %{conn: conn} do
      deck = deck("Tem Nome")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live |> element("button[phx-click='start-rename']") |> render_click()

      html = live |> form("form[phx-submit='rename']", deck: %{name: "   "}) |> render_submit()

      assert html =~ "O deck precisa de um nome"
      assert Decks.get_deck(deck.id).name == "Tem Nome"
    end

    test "cancelling leaves the name alone", %{conn: conn} do
      deck = deck("Intocado")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live |> element("button[phx-click='start-rename']") |> render_click()
      html = live |> element("button[phx-click='cancel-rename']") |> render_click()

      assert html =~ "Intocado"
      refute has_element?(live, "form[phx-submit='rename']")
    end
  end

  describe "duplicating" do
    test "copies the list as it stands, not as it was imported", %{conn: conn} do
      deck = deck("Original")
      # An edit after the import: `raw_decklist` still says otherwise.
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      live |> element("button[phx-click='duplicate']") |> render_click()

      assert copy = Enum.find(Decks.list_decks(), &(&1.name == "Original — cópia"))

      names = copy |> Decks.list_deck_cards() |> Enum.map(& &1.card.name)
      refute "Sol Ring" in names
      assert "Nature's Lore" in names
    end

    test "the commander stays a commander in the copy", %{conn: conn} do
      deck = deck("Com Comandante")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")
      live |> element("button[phx-click='duplicate']") |> render_click()

      copy = Enum.find(Decks.list_decks(), &(&1.name == "Com Comandante — cópia"))

      assert [%{card: %{name: "Nature's Lore"}}] =
               copy |> Decks.list_deck_cards() |> Enum.filter(&(&1.board == :commander))
    end

    test "the original is untouched", %{conn: conn} do
      deck = deck("Original")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")
      live |> element("button[phx-click='duplicate']") |> render_click()

      assert Decks.get_deck(deck.id).name == "Original"
      assert length(Decks.list_decks()) == 2
    end
  end

  describe "deleting from the deck's own page" do
    test "goes back to the table with the deck gone", %{conn: conn} do
      deck = deck("Para Apagar")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live |> element("button[phx-click='delete']") |> render_click()

      assert Decks.list_decks() == []
    end

    test "the confirmation names what goes along", %{conn: conn} do
      deck = deck()
      insert(:consult, deck: deck)

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "1 consulta(s)"
    end
  end

  describe "downloading the list" do
    # The deck goes back out the door it came in through: the same format the
    # app imports, and the one a shop's bulk-add box reads.
    test "serves the current cards as decklist text", %{conn: conn} do
      deck = deck("Iroh das Lontra")
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")

      response = conn |> get(~p"/decks/#{deck.id}/lista.txt") |> response(200)

      assert response =~ "Commander:\n1 Nature's Lore"
      assert response =~ "4 Forest"
      refute response =~ "Sol Ring"
    end

    test "the filename is a filename, not the deck's name with spaces in it", %{conn: conn} do
      deck = deck("Iroh das Lontra — otimizado")

      conn = get(conn, ~p"/decks/#{deck.id}/lista.txt")

      assert [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition == ~s(attachment; filename="iroh-das-lontra-otimizado.txt")
    end

    test "round-trips: what it serves, the importer reads back", %{conn: conn} do
      deck = deck("Ida e Volta")

      text = conn |> get(~p"/decks/#{deck.id}/lista.txt") |> response(200)

      {:ok, reimported} = Decks.import_from_text(text, %{name: "De Volta", source: :paste})

      assert Enum.sort(Enum.map(Decks.list_deck_cards(reimported), &{&1.card.name, &1.board})) ==
               Enum.sort(Enum.map(Decks.list_deck_cards(deck), &{&1.card.name, &1.board}))
    end
  end
end
