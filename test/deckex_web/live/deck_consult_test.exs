defmodule DeckexWeb.DeckConsultTest do
  use DeckexWeb.ConnCase, async: true

  import Mox
  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks

  setup :verify_on_exit!

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Counterspell\n4 Forest", %{
        name: "Deck da Consulta",
        source: :paste
      })

    %{deck: deck}
  end

  test "every finding offers a consult", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    assert live
           |> element("button[phx-value-code='interaction.no_board_wipes']")
           |> has_element?()
  end

  test "asking about a finding creates a scoped consult", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    live
    |> element("button[phx-value-code='interaction.no_board_wipes']")
    |> render_click()

    assert [%{lens: :finding, finding_code: "interaction.no_board_wipes"}] =
             Consults.list_for_deck(deck)
  end

  test "the whole deck can be consulted at once", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}")

    live |> element("button[phx-click='consult-full']") |> render_click()

    assert [%{lens: :full}] = Consults.list_for_deck(deck)
  end

  test "a finished consult renders its cuts and adds", %{conn: conn, deck: deck} do
    {:ok, consult} = Consults.request(deck, :full)

    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "diagnosis" => "Falta interação nesse deck.",
         "cuts" => [%{"card" => "Sol Ring", "reason" => "exemplo de corte"}],
         "adds" => [%{"card" => "Swords to Plowshares", "reason" => "remoção barata"}]
       }}
    end)

    {:ok, _done} = Consults.run(consult)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Falta interação nesse deck."
    assert html =~ "Swords to Plowshares"
    assert html =~ "remoção barata"
  end

  test "the exact prompt is available to copy", %{conn: conn, deck: deck} do
    {:ok, _consult} = Consults.request(deck, :full)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Ver o prompt"
  end
end
