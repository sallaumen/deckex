defmodule DeckexWeb.CardRulesLiveTest do
  @moduledoc """
  The screen where the owner says what happens to a card, once, for good.
  """
  use DeckexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Decks.Versions
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

      assert html =~ "Proponho guardar"
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

      assert html =~ "1 obrigatória."

      assert [%{card_name: "Sol Ring", stance: :locked, note: "Tudo passa pelo Sol Ring."}] =
               Decks.card_notes(deck)
    end

    # Unticking everything must not leave a button that promises to do nothing.
    test "a card he unticks is left alone, and the button stops offering",
         %{conn: conn, deck: deck} do
      {:ok, deck} = Decks.put_dossier(deck, %{"sinergias" => "Tudo passa pelo Sol Ring."})

      {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/cartas")
      html = live |> element("button[phx-click='varrer']") |> render_click()
      assert html =~ "Proponho guardar (1 de 1)"

      html =
        live
        |> element("input[phx-click='marcar-proposta'][phx-value-card='Sol Ring']")
        |> render_click()

      assert html =~ "Proponho guardar (0 de 1)"

      assert live
             |> element("button[phx-click='trancar-marcadas']")
             |> render() =~ "disabled"

      assert Decks.card_notes(deck) == []
    end

    # Invisible one row at a time: locking eight cards feels like nothing, and
    # that is how a real deck ended up with a third of it untouchable.
    test "a deck locked past the point of being optimisable says so",
         %{conn: conn, deck: deck} do
      {:ok, _rules} = Decks.put_card_rules(deck, "Sol Ring\nCultivate", :locked)

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/cartas")

      assert html =~ "do deck está obrigatório"
      assert html =~ "sem espaço para melhorar"
    end

    test "a deck with room left says nothing about it", %{conn: conn, deck: deck} do
      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/cartas")

      refute html =~ "do deck está obrigatório"
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

    # The deck changes, the list changes, and an answer from yesterday about a
    # list that no longer exists cannot be the last word forever.
    test "he can ask again once an answer has landed", %{conn: conn, deck: deck} do
      {:ok, consult} = Consults.request(deck, :pilares)

      {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/cartas")
      refute html =~ "Perguntar"
      assert html =~ "A IA está lendo as cartas"

      consult
      |> Ecto.Changeset.change(%{status: :done, response: %{"pilares" => []}})
      |> Repo.update!()

      {:ok, reloaded, html} = live(conn, ~p"/decks/#{deck.id}/cartas")

      assert html =~ "Perguntar de novo (1 consulta)"
      assert html =~ "última resposta"
      assert has_element?(reloaded, "button[phx-click='perguntar-ia']")
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

      assert html =~ "Proponho guardar"
      assert html =~ "metade do combo"
      assert html =~ "a IA leu as cartas"
    end
  end

  test "text with no card in it is refused out loud", %{conn: conn, deck: deck} do
    {:ok, live, _html} = live(conn, ~p"/decks/#{deck.id}/cartas")

    html = live |> form("#colar", %{lote: %{texto: "# só um título\n\n"}}) |> render_submit()

    assert html =~ "Não achei nenhum nome de carta nesse texto"
  end

  # The regression from a real deck: four notes citing cards gone since an
  # older version rode into every briefing until the model itself had to flag
  # them as residue. The note is the owner's and only he can prune it — so the
  # screen points.
  test "a note citing a card that left the list gets the pointer",
       %{conn: conn, deck: deck} do
    # Cultivate enters the version history, then leaves the working list.
    {:ok, _card} = Decks.add_card(deck, "Cultivate")
    {:ok, _version} = Versions.mark(deck, origin: :manual)
    {:ok, :removed} = Decks.remove_card(deck, "Cultivate")

    {:ok, _note} = Decks.put_card_note(deck, "Sol Ring", "a cadeia fecha com Cultivate")

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/cartas")

    assert html =~ "Esta nota cita Cultivate"
    assert html =~ "não está mais na lista"
  end

  test "a note citing only present cards stays quiet", %{conn: conn, deck: deck} do
    {:ok, _note} = Decks.put_card_note(deck, "Sol Ring", "o motor de mana do deck")

    {:ok, _live, html} = live(conn, ~p"/decks/#{deck.id}/cartas")

    refute html =~ "não está mais na lista"
  end
end
