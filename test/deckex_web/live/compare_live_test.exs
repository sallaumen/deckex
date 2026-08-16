defmodule DeckexWeb.CompareLiveTest do
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Decks

  defp deck(name, text) do
    {:ok, deck} = Decks.import_from_text(text, %{name: name, source: :paste})

    deck
  end

  defp pair do
    CatalogueFixture.seed!(~w(sol_ring forest natures_lore cultivate counterspell))

    original =
      deck("Frodo 1.0", "Commander:\n1 Nature's Lore\n\nDeck:\n1 Sol Ring\n4 Forest")

    forked =
      deck(
        "Frodo 1.0 — otimizado",
        "Commander:\n1 Nature's Lore\n\nDeck:\n1 Cultivate\n1 Counterspell\n4 Forest"
      )

    %{original: original, forked: forked}
  end

  describe "comparing two decks" do
    test "prices the gap between two decks that forked", %{conn: conn} do
      %{original: original, forked: forked} = pair()

      {:ok, _live, html} = live(conn, ~p"/comparar?de=#{original.id}&para=#{forked.id}")

      assert html =~ "Comprar (2)"
      assert html =~ "Cultivate"
      assert html =~ "Counterspell"
      assert html =~ "Fica de fora (1)"
      assert html =~ "Sol Ring"
    end

    test "read the other way it is the opposite list", %{conn: conn} do
      %{original: original, forked: forked} = pair()

      {:ok, live, _html} = live(conn, ~p"/comparar")

      html =
        live
        |> form("#comparar", %{de: forked.id, para: original.id})
        |> render_change()

      assert html =~ "Comprar (1)"
      assert html =~ "Fica de fora (2)"
    end

    test "the same deck on both sides says so instead of showing nothing", %{conn: conn} do
      %{original: original} = pair()

      {:ok, live, _html} = live(conn, ~p"/comparar")

      html =
        live
        |> form("#comparar", %{de: original.id, para: original.id})
        |> render_change()

      assert html =~ "mesmo deck dos dois lados"
    end

    test "the buy list downloads as text a shop can read", %{conn: conn} do
      %{original: original, forked: forked} = pair()

      conn = get(conn, ~p"/comparar/#{original.id}/para/#{forked.id}/compras.txt")

      assert response(conn, 200) == "1 Counterspell\n1 Cultivate\n"
    end

    test "one deck on the table has nothing to compare", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring forest))
      deck("Sozinho", "1 Sol Ring\n4 Forest")

      {:ok, _live, html} = live(conn, ~p"/comparar")

      assert html =~ "Precisa de dois decks"
    end
  end

  describe "the way in" do
    test "A Mesa offers the comparison once there are two decks", %{conn: conn} do
      pair()

      {:ok, live, _html} = live(conn, ~p"/")

      assert live |> element(~s|a[href="/comparar"]|) |> has_element?()
    end

    test "one deck, no offer", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring forest))
      deck("Sozinho", "1 Sol Ring\n4 Forest")

      {:ok, live, _html} = live(conn, ~p"/")

      refute live |> element(~s|a[href="/comparar"]|) |> has_element?()
    end
  end
end
