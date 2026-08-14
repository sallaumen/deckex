defmodule DeckexWeb.BracketLensTest do
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest rhystic_study))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Rhystic Study\n4 Forest", %{
        name: "Deck do Bracket",
        source: :paste
      })

    %{deck: deck}
  end

  test "the floor and its reason are on the page", %{conn: conn, deck: deck} do
    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    # Rhystic Study is a Game Changer, so the floor is 3.
    assert html =~ "Bracket 3"
    assert html =~ "Upgraded"
    assert html =~ "Rhystic Study"
    assert html =~ "pelo menos 6 turnos"
  end

  test "the questions the engine cannot answer are shown as questions",
       %{conn: conn, deck: deck} do
    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "O motor não consegue responder"
    assert html =~ "combo de duas cartas"
  end

  test "the bracket lens is pickable and asks about combo and speed",
       %{conn: conn, deck: deck} do
    {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Em que bracket esse deck está?"

    live
    |> form("form[phx-submit='consult-full']", consult: %{lens: "bracket", model: "sonnet"})
    |> render_submit()

    assert [consult] = Enum.filter(Consults.list_for_deck(deck), &(&1.lens == :bracket))
    assert consult.briefing =~ "Measured floor: **Bracket 3**"
    assert consult.briefing =~ "two-card combo"
    assert consult.briefing =~ "Suggest no cuts and no adds"
  end

  test "a finished bracket answer renders its own shape", %{conn: conn, deck: deck} do
    {:ok, consult} = Consults.request(deck, :bracket)

    {:ok, _done} =
      consult
      |> Ecto.Changeset.change(%{
        status: :done,
        response: %{
          "bracket" => 3,
          "combo" => "Nenhum que eu veja.",
          "speed" => "Fecha por volta do turno 8.",
          "justificativa" => "Três Game Changers, sem combo rápido.",
          "para_descer" => "Trocar Rhystic Study por Phyrexian Arena."
        }
      })
      |> Deckex.Repo.update()

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}")

    assert html =~ "Nenhum que eu veja."
    assert html =~ "Fecha por volta do turno 8."
    assert html =~ "Para descer um bracket:"
  end
end
