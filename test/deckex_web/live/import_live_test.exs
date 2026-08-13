defmodule DeckexWeb.ImportLiveTest do
  use DeckexWeb.ConnCase, async: true

  import Mox
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Error

  setup :verify_on_exit!

  describe "the page" do
    test "offers both paths and is honest about the blocked one", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/importar")

      assert html =~ "Colar a lista"
      assert html =~ "Link do Moxfield"
      # The Moxfield panel must say why it usually fails before the user spends
      # a click on it.
      assert html =~ "403"
    end
  end

  describe "pasting a decklist" do
    test "imports the deck and lands on it", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring forest))

      {:ok, live, _html} = live(conn, ~p"/importar")

      live
      |> form("form[phx-submit=paste]",
        paste: %{name: "Colado", decklist: "1 Sol Ring\n4 Forest"}
      )
      |> render_submit()

      assert_redirect(live, ~p"/decks/#{deck_id("Colado")}")
    end

    test "names an unnamed deck rather than refusing it", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring))

      {:ok, live, _html} = live(conn, ~p"/importar")

      live
      |> form("form[phx-submit=paste]", paste: %{name: "", decklist: "1 Sol Ring"})
      |> render_submit()

      assert [%{name: "Deck sem nome"}] = Decks.list_decks()
    end

    test "shows the domain error instead of crashing on an empty list", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/importar")

      html =
        live
        |> form("form[phx-submit=paste]", paste: %{name: "Vazio", decklist: "conversa fiada"})
        |> render_submit()

      assert html =~ "Não achei nenhuma carta"
      assert html =~ "empty_decklist"
      assert Decks.list_decks() == []
    end
  end

  describe "syncing a URL" do
    test "imports when Moxfield answers", %{conn: conn} do
      CatalogueFixture.seed!(~w(sol_ring))

      expect(Deckex.Moxfield.Mock, :fetch_deck, fn _id ->
        {:ok, %{name: "Do Moxfield", decklist: "1 Sol Ring"}}
      end)

      {:ok, live, _html} = live(conn, ~p"/importar")

      live
      |> form("form[phx-submit=sync]", url: %{url: "https://moxfield.com/decks/abc123"})
      |> render_submit()

      assert_redirect(live, ~p"/decks/#{deck_id("Do Moxfield")}")
    end

    test "surfaces a Cloudflare block on the page, pointing at the paste form", %{conn: conn} do
      expect(Deckex.Moxfield.Mock, :fetch_deck, fn _id ->
        {:error,
         Error.new(:moxfield_blocked, "O Moxfield bloqueou a busca. Você pode colar a lista.")}
      end)

      {:ok, live, _html} = live(conn, ~p"/importar")

      html =
        live
        |> form("form[phx-submit=sync]", url: %{url: "https://moxfield.com/decks/abc123"})
        |> render_submit()

      assert html =~ "bloqueou a busca"
      assert html =~ "moxfield_blocked"
      # The paste panel is still right there.
      assert html =~ "Colar a lista"
    end
  end

  defp deck_id(name) do
    Decks.list_decks() |> Enum.find(&(&1.name == name)) |> Map.fetch!(:id)
  end
end
