defmodule DeckexWeb.CardRulesLiveTest do
  @moduledoc """
  The screen where the owner says what happens to a card, once, for good.
  """
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Repo

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{
        name: "Deck das Ordens",
        source: :paste
      })

    %{deck: deck}
  end

  test "a deck nobody has decided anything about says what the screen is for",
       %{conn: conn, deck: deck} do
    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/cartas")

    assert html =~ "Suas cartas"
    assert html =~ "Você ainda não mandou nada sobre carta nenhuma"
  end

  test "a pasted block becomes orders, reasons and all", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/cartas")

    html =
      live
      |> form("#colar", %{lote: %{texto: "Sol Ring | é o motor\nCultivate"}})
      |> render_submit()

    assert html =~ "2 cartas guardadas como obrigatórias"
    assert html =~ "é o motor"
    assert Decks.locked_cards(deck) == ["Cultivate", "Sol Ring"]
  end

  # The most useful line on the page: an order about a card the deck does not
  # have is the one still waiting to be acted on, and nothing else would say so.
  test "an order about a card the deck lacks is marked as outside it",
       %{conn: conn, deck: deck} do
    {:ok, _rule} = Decks.put_card_rules(deck, "Sol Ring\nPrize Pig", :locked)

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/cartas")

    assert html =~ "Prize Pig"
    assert html =~ "fora do deck"
  end

  test "a card can be promoted from asked-for to untouchable", %{conn: conn, deck: deck} do
    {:ok, _rule} = Decks.put_card_rules(deck, "Cultivate | quero essa", :wanted)

    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/cartas")

    html =
      live
      |> element(
        "button[phx-click='mudar'][phx-value-card='Cultivate'][phx-value-stance='locked']"
      )
      |> render_click()

    assert html =~ "Cultivate agora é obrigatória"
    assert [%{stance: :locked, note: "quero essa"}] = Decks.card_notes(deck)
  end

  test "the reason is editable where the order is", %{conn: conn, deck: deck} do
    {:ok, _rule} = Decks.put_card_rules(deck, "Sol Ring", :locked)
    [rule] = Decks.card_notes(deck)

    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/cartas")

    live
    |> form("#motivo-#{rule.id}", %{card: "Sol Ring", motivo: "metade do combo"})
    |> render_submit()

    assert [%{note: "metade do combo", stance: :locked}] = Decks.card_notes(deck)
  end

  test "an order can be taken back", %{conn: conn, deck: deck} do
    {:ok, _rule} = Decks.put_card_rules(deck, "Sol Ring", :locked)

    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/cartas")

    html =
      live
      |> element("button[phx-click='esquecer'][phx-value-card='Sol Ring']")
      |> render_click()

    assert html =~ "Sol Ring saiu das suas decisões"
    assert Decks.card_notes(deck) == []
  end

  describe "achar as óbvias" do
    test "reads the dossier and proposes, without locking anything", %{conn: conn, deck: deck} do
      {:ok, deck} =
        Decks.put_dossier(deck, %{
          "sinergias" => "O motor é o Sol Ring virando dois manas no turno um."
        })

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/cartas")
      html = live |> element("button[phx-click='varrer']") |> render_click()

      assert html =~ "Proponho trancar"
      assert html =~ "Sol Ring"
      assert html =~ "virando dois manas"
      assert html =~ "está no dossiê"
      # Proposing is not deciding.
      assert Decks.card_notes(deck) == []
    end

    test "locking the ticked ones keeps the evidence as the reason",
         %{conn: conn, deck: deck} do
      {:ok, deck} = Decks.put_dossier(deck, %{"sinergias" => "Tudo passa pelo Sol Ring."})

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/cartas")
      live |> element("button[phx-click='varrer']") |> render_click()
      html = live |> element("button[phx-click='trancar-marcadas']") |> render_click()

      assert html =~ "1 carta trancada"

      assert [%{card_name: "Sol Ring", stance: :locked, note: "Tudo passa pelo Sol Ring."}] =
               Decks.card_notes(deck)
    end

    # Unticking everything must not leave a button that promises to do nothing.
    test "a card he unticks is left alone, and the button stops offering",
         %{conn: conn, deck: deck} do
      {:ok, deck} = Decks.put_dossier(deck, %{"sinergias" => "Tudo passa pelo Sol Ring."})

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/cartas")
      html = live |> element("button[phx-click='varrer']") |> render_click()
      assert html =~ "Proponho trancar (1 de 1)"

      html =
        live
        |> element("input[phx-click='marcar-proposta'][phx-value-card='Sol Ring']")
        |> render_click()

      assert html =~ "Proponho trancar (0 de 1)"

      assert live
             |> element("button[phx-click='trancar-marcadas']")
             |> render() =~ "disabled"

      assert Decks.card_notes(deck) == []
    end

    # An empty sweep is not a failure — it says which of the two sources came up
    # dry, and the paid one is right there.
    test "a deck with no dossier is told why the free pass found nothing",
         %{conn: conn, deck: deck} do
      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/cartas")

      html = live |> element("button[phx-click='varrer']") |> render_click()

      assert html =~ "ainda não tem dossiê"
      assert html =~ "Perguntar para a IA"
    end

    test "asking the model costs one consult, and says so before spending",
         %{conn: conn, deck: deck} do
      {:ok, live, html} = live(conn, ~p"/decks/#{deck.id}/cartas")
      assert html =~ "Perguntar para a IA (1 consulta)"

      html = live |> element("button[phx-click='perguntar-ia']") |> render_click()

      assert html =~ "A IA está lendo as cartas"
      assert [%{lens: :pilares, status: :pending}] = Consults.list_for_deck(deck)
    end

    test "the answer becomes proposals in the model's own words",
         %{conn: conn, deck: deck} do
      {:ok, consult} = Consults.request(deck, :pilares)

      answered =
        consult
        |> Ecto.Changeset.change(%{
          status: :done,
          response: %{
            "leitura" => "É um deck de rampa.",
            "pilares" => [%{"carta" => "Sol Ring", "motivo" => "metade do combo"}]
          }
        })
        |> Repo.update!()

      assert answered.status == :done

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/cartas")

      assert html =~ "Proponho trancar"
      assert html =~ "metade do combo"
      assert html =~ "a IA leu as cartas"
    end
  end

  test "text with no card in it is refused out loud", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/cartas")

    html = live |> form("#colar", %{lote: %{texto: "# só um título\n\n"}}) |> render_submit()

    assert html =~ "Não achei nenhum nome de carta nesse texto"
  end
end
