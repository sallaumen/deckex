defmodule DeckexWeb.VersionsLiveTest do
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Decks.Versions

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest natures_lore cultivate counterspell))

    {:ok, deck} =
      Decks.import_from_text("Commander:\n1 Nature's Lore\n\nDeck:\n1 Sol Ring\n4 Forest", %{
        name: "Deck Versionado",
        source: :paste
      })

    deck
  end

  describe "the history" do
    test "shows the version the import left behind", %{conn: conn} do
      deck = deck()

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/versoes")

      assert html =~ "v1"
      assert html =~ "Como foi importado"
      assert html =~ "importado"
    end

    test "each version says what it did", %{conn: conn} do
      deck = deck()
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")
      {:ok, _} = Decks.add_card(deck, "Cultivate")
      {:ok, _} = Versions.mark(deck, label: "Trocando Sol Ring")

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/versoes")

      assert html =~ "Trocando Sol Ring"
      assert html =~ "Cultivate"
      assert html =~ "Sol Ring"
    end

    # The owner who edited five cards and never marked a version should read it
    # on the screen, not deduce it from a diff.
    test "warns when the deck moved away from its last version", %{conn: conn} do
      deck = deck()
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/versoes")

      assert html =~ "O deck mudou desde a última versão"
    end

    test "says nothing about drift when there is none", %{conn: conn} do
      deck = deck()

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/versoes")

      refute html =~ "O deck mudou desde a última versão"
    end

    test "marking a version puts it at the top of the list", %{conn: conn} do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Cultivate")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/versoes")

      html = live |> element("button", "Marcar versão agora") |> render_click()

      assert html =~ "v2"
      assert html =~ "marcada por você"
      refute html =~ "O deck mudou desde a última versão"
    end

    # The version just made is the one the owner wants to look at. Leaving the
    # comparison on "v1 against v1" made the new version look like a no-op.
    test "the comparison moves to the version just marked", %{conn: conn} do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Cultivate")

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/versoes")
      html = live |> element("button", "Marcar versão agora") |> render_click()

      assert html =~ "Comprar (1)"
      assert html =~ "Cultivate"
    end
  end

  describe "going back" do
    test "restores the deck and says so", %{conn: conn} do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Counterspell")
      {:ok, _} = Versions.mark(deck)

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/versoes")

      html = live |> element(~s|button[phx-value-number="1"]|) |> render_click()

      assert html =~ "Deck voltou para a v1"

      names = deck |> Decks.list_deck_cards() |> Enum.map(& &1.card.name) |> Enum.sort()
      assert names == ["Forest", "Nature's Lore", "Sol Ring"]
    end

    # History is a record, not a tree to prune: the version we left is still
    # on screen after we go back.
    test "the versions after the restored one stay in the list", %{conn: conn} do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Counterspell")
      {:ok, _} = Versions.mark(deck)

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/versoes")
      html = live |> element(~s|button[phx-value-number="1"]|) |> render_click()

      assert html =~ "v2"
    end
  end

  describe "comparing two versions" do
    setup do
      deck = deck()
      {:ok, _} = Decks.remove_card(deck, "Sol Ring")
      {:ok, _} = Decks.add_card(deck, "Cultivate")
      {:ok, _} = Decks.add_card(deck, "Counterspell")
      {:ok, _v2} = Versions.mark(deck, label: "Rodada de agosto")

      %{deck: deck}
    end

    test "opens on the oldest against the newest", %{conn: conn, deck: deck} do
      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/versoes")

      assert html =~ "Comprar (2)"
      assert html =~ "Cultivate"
      assert html =~ "Sai do deck (1)"
    end

    test "the buy list has a total and a download", %{conn: conn, deck: deck} do
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/versoes")

      assert live
             |> element(~s|a[href="/decks/#{deck.id}/versoes/1/para/2/compras.txt"]|)
             |> has_element?()
    end

    test "read the other way it is the opposite list", %{conn: conn, deck: deck} do
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/versoes")

      html = live |> form("form[phx-change=comparar]", %{from: "2", to: "1"}) |> render_change()

      assert html =~ "Comprar (1)"
      assert html =~ "Sai do deck (2)"
    end

    test "a version against itself asks for nothing", %{conn: conn, deck: deck} do
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/versoes")

      html = live |> form("form[phx-change=comparar]", %{from: "1", to: "1"}) |> render_change()

      assert html =~ "as listas são iguais"
    end
  end

  describe "the download" do
    test "hands over the buy list as text a shop can read", %{conn: conn} do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Cultivate")
      {:ok, _} = Versions.mark(deck)

      conn = get(conn, ~p"/decks/#{deck.id}/versoes/1/para/2/compras.txt")

      assert response(conn, 200) == "1 Cultivate\n"
      assert response_content_type(conn, :txt) =~ "text/plain"
    end
  end

  describe "the way in" do
    test "the deck page links to the history with a count", %{conn: conn} do
      deck = deck()

      {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}")

      assert html =~ "Versões (1)"
      assert live |> element(~s|a[href="/decks/#{deck.id}/versoes"]|) |> has_element?()
    end
  end

  test "a deck that does not exist sends you back to the table", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(conn, ~p"/decks/#{Ecto.UUID.generate()}/versoes")
  end
end
