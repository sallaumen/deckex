defmodule Deckex.Decks.PillarsTest do
  @moduledoc """
  Proposing the obvious locks instead of making the owner map them one by one.

  Mapping card by card is work, and work nobody does is protection nobody has.
  Most of the answer is already written down — the scout named the synergies,
  and past reviews named the cards a stage read wrong. This is that half,
  which costs nothing.
  """
  use Deckex.DataCase, async: true

  alias Deckex.Decks

  defp deck do
    Deckex.CatalogueFixture.seed!(~w(sol_ring forest cultivate counterspell rhystic_study))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n1 Cultivate\n1 Counterspell\n4 Forest", %{
        name: "Deck dos Pilares",
        source: :paste
      })

    deck
  end

  defp with_dossier(deck, dossier) do
    {:ok, deck} = Decks.put_dossier(deck, dossier)

    deck
  end

  describe "what the dossier already says" do
    test "a card named in the synergies is proposed, with the sentence that named it" do
      deck =
        with_dossier(deck(), %{
          "sinergias" =>
            "O motor é o Sol Ring virando dois manas no turno um. Cultivate só arruma cor.",
          "linhas_de_vitoria" => "Fecha no combate."
        })

      assert [%{name: "Sol Ring", source: :dossier, reason: reason}, _cultivate] =
               Decks.pillar_proposals(deck)

      assert reason =~ "virando dois manas"
    end

    # The correction the owner paid for: the first version of this sweep turned
    # every card in a synergy paragraph into an untouchable, and three real
    # decks came out with 22%, 29% and 32% of their cuttable cards locked. A
    # pipeline that cannot cut a third of the deck cannot improve it.
    test "one sentence naming several cards is an observation, not several orders" do
      deck =
        with_dossier(deck(), %{
          "sinergias" =>
            "O pacote de rampa é Sol Ring, Cultivate e Counterspell, e é ele que segura o plano."
        })

      proposals = Decks.pillar_proposals(deck)

      assert length(proposals) == 3
      assert Enum.all?(proposals, &(&1.stance == :note))
    end

    test "a sentence written about one card keeps its order" do
      deck =
        with_dossier(deck(), %{
          "sinergias" => "Tudo passa pelo Sol Ring. Cultivate e Counterspell são só o resto."
        })

      by_name = Map.new(Decks.pillar_proposals(deck), &{&1.name, &1.stance})

      assert by_name["Sol Ring"] == :locked
      assert by_name["Cultivate"] == :note
      assert by_name["Counterspell"] == :note
    end

    test "a card named in the win lines counts the same" do
      deck =
        with_dossier(deck(), %{
          "sinergias" => "Nada de especial.",
          "linhas_de_vitoria" => "O jogo fecha com Counterspell segurando a resposta da mesa."
        })

      assert [%{name: "Counterspell", source: :dossier, reason: reason}] =
               Decks.pillar_proposals(deck)

      assert reason =~ "segurando a resposta"
    end

    # `plano` names cards as examples and `fraquezas` names them as problems.
    # Only the synergies and the win lines name a card because the deck needs it.
    test "the plan and the weaknesses are not evidence of anything" do
      deck =
        with_dossier(deck(), %{
          "plano" => "Rampar com Sol Ring e Cultivate.",
          "fraquezas" => "Counterspell é a única resposta."
        })

      assert Decks.pillar_proposals(deck) == []
    end

    test "a basic land is nobody's pillar" do
      deck = with_dossier(deck(), %{"sinergias" => "A base é Forest e mais Forest."})

      assert Decks.pillar_proposals(deck) == []
    end

    test "a deck with no dossier has nothing free to give" do
      assert Decks.pillar_proposals(deck()) == []
    end

    # The commander is protected by the engine already; proposing it is noise in
    # a list read for approval.
    test "the commander is not proposed" do
      Deckex.CatalogueFixture.seed!(~w(sol_ring forest natures_lore))

      {:ok, deck} =
        Decks.import_from_text("Commander:\n1 Nature's Lore\n\nDeck:\n1 Sol Ring\n4 Forest", %{
          name: "Deck do Comandante",
          source: :paste
        })

      deck = with_dossier(deck, %{"sinergias" => "Tudo gira em volta de Nature's Lore."})

      assert Decks.pillar_proposals(deck) == []
    end
  end

  describe "what a past review already taught" do
    test "a card a review explained is proposed in his own words" do
      deck = deck()

      {:ok, _note} =
        Decks.put_card_note(deck, "Counterspell", "é a única resposta a combo aqui", :review)

      assert [%{name: "Counterspell", source: :review, reason: "é a única resposta a combo aqui"}] =
               Decks.pillar_proposals(deck)
    end

    test "a note he typed himself is not a review's finding" do
      deck = deck()
      {:ok, _note} = Decks.put_card_note(deck, "Counterspell", "acho que é boa")

      assert Decks.pillar_proposals(deck) == []
    end
  end

  describe "what he has already decided" do
    # Re-proposing a card he already locked is the app offering him work he
    # finished, and it is how a list of eight becomes a list nobody reads.
    test "a card already locked is never proposed again" do
      deck = deck()
      {:ok, _rule} = Decks.put_card_rules(deck, "Sol Ring", :locked)

      deck = with_dossier(deck, %{"sinergias" => "O motor é o Sol Ring."})

      assert Decks.pillar_proposals(deck) == []
    end

    test "a card he asked for is a decision too" do
      deck = deck()
      {:ok, _rule} = Decks.put_card_rules(deck, "Sol Ring", :wanted)

      deck = with_dossier(deck, %{"sinergias" => "O motor é o Sol Ring."})

      assert Decks.pillar_proposals(deck) == []
    end
  end

  describe "what only the model can see" do
    # A combo nobody has written about leaves no trace in prose. This is the
    # half the free sweep cannot do, and the reason the paid button exists.
    test "the model's own reading comes first, in the deck's spelling" do
      deck = with_dossier(deck(), %{"sinergias" => "O motor é o Sol Ring."})

      rows = [
        %{"carta" => "counterspell", "motivo" => "trava o combo da mesa"},
        %{"carta" => "Sol Ring", "motivo" => "o deck inteiro depende dele no turno um"}
      ]

      assert [
               %{name: "Counterspell", source: :ia},
               %{name: "Sol Ring", source: :ia, reason: "o deck inteiro depende dele no turno um"}
             ] = Decks.pillar_proposals(deck, rows)
    end

    # A model naming a card the deck does not hold is proposing an add, and
    # this screen does not add cards.
    test "a card that is not in the deck is dropped rather than proposed" do
      deck = deck()
      rows = [%{"carta" => "Mana Crypt", "motivo" => "seria bom"}]

      assert Decks.pillar_proposals(deck, rows) == []
    end
  end
end
