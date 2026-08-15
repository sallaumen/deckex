defmodule DeckexWeb.MesaLiveTest do
  use DeckexWeb.ConnCase, async: true

  import Deckex.Factory
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Optimizations
  alias Deckex.Settings

  defp deck(name \\ "Deck da Mesa") do
    CatalogueFixture.seed!(~w(sol_ring forest))

    {:ok, deck} = Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: name, source: :paste})

    deck
  end

  describe "how the decks are laid out" do
    test "cards by default, and the toggle switches to a list", %{conn: conn} do
      deck = deck()

      {:ok, live, html} = live(conn, ~p"/")

      assert html =~ deck.name
      assert has_element?(live, "button[phx-value-to='lista']")

      listed = live |> element("button[phx-value-to='lista']") |> render_click()

      assert listed =~ deck.name
      assert Settings.get(:deck_layout) == "lista"
    end

    # A layout you have to re-pick on every visit is not a preference.
    test "the choice survives leaving the page", %{conn: conn} do
      deck()
      {:ok, _v} = Settings.put(:deck_layout, "lista")

      {:ok, live, _html} = live(conn, ~p"/")

      assert has_element?(live, "button[phx-value-to='lista'][aria-pressed='true']")
    end

    test "the toggle is hidden with no decks to lay out", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/")

      refute has_element?(live, "button[phx-value-to='lista']")
    end
  end

  describe "deleting a deck" do
    test "removes it from the table", %{conn: conn} do
      deck = deck("Deck Descartável")

      {:ok, live, _html} = live(conn, ~p"/")

      live |> element("button[phx-value-id='#{deck.id}']") |> render_click()

      # Not `refute html =~ name` — the flash confirming the deletion says the
      # name too, and a test that passes only because the app stayed silent is
      # the wrong test.
      refute has_element?(live, "button[phx-value-id='#{deck.id}']")
      assert Decks.list_decks() == []
    end

    # A consult cost money and a run is a record of a decision; the owner is
    # told what goes with the deck before the click, not after.
    test "the confirmation counts what else disappears", %{conn: conn} do
      deck = deck()
      insert(:consult, deck: deck)
      insert(:optimization, deck: deck, status: :done)

      {:ok, live, html} = live(conn, ~p"/")

      assert html =~ "1 consulta(s) e 1 otimização(ões)"
      assert has_element?(live, "button[phx-value-id='#{deck.id}'][data-confirm]")
    end

    test "a deck with nothing attached says so plainly", %{conn: conn} do
      deck()

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "A lista some; o catálogo de cartas fica."
    end

    # The run's jobs would keep executing against rows that no longer exist.
    test "a deck with a run in flight is refused, with the reason", %{conn: conn} do
      deck = deck()
      insert(:optimization, deck: deck, status: :running)

      {:ok, live, _html} = live(conn, ~p"/")

      html = live |> element("button[phx-value-id='#{deck.id}']") |> render_click()

      assert html =~ "Cancele ela antes de apagar o deck"
      assert Decks.get_deck(deck.id)
    end

    test "cancelling the run frees the deck to be deleted", %{conn: conn} do
      deck = deck()
      run = insert(:optimization, deck: deck, status: :running)

      {:ok, _cancelled} = Optimizations.cancel(run)

      assert {:ok, _deleted} = Decks.delete_deck(Decks.get_deck(deck.id))
    end
  end
end
