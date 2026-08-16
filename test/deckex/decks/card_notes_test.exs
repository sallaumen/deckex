defmodule Deckex.Decks.CardNotesTest do
  use Deckex.DataCase, async: true

  alias Deckex.Analysis
  alias Deckex.CatalogueFixture
  alias Deckex.Consults.Briefing
  alias Deckex.Decks

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck com Memória", source: :paste})

    deck
  end

  describe "what the owner says about a card" do
    test "is kept against the deck, not against a run" do
      deck = deck()

      {:ok, note} =
        Decks.put_card_note(deck, "Jaheira, Friend of the Forest", "transforma Food em criatura")

      assert note.card_name == "Jaheira, Friend of the Forest"
      assert note.source == :manual
      assert [^note] = Decks.card_notes(deck)
    end

    # He corrects himself; he does not accumulate two contradictory notes about
    # the same card.
    test "the second word about a card replaces the first" do
      deck = deck()

      {:ok, _first} = Decks.put_card_note(deck, "Sol Ring", "fica sempre")
      {:ok, second} = Decks.put_card_note(deck, "Sol Ring", "pensando melhor, pode sair")

      assert [%{note: "pensando melhor, pode sair"}] = Decks.card_notes(deck)
      assert second.note == "pensando melhor, pode sair"
    end

    test "the way to unsay something is to erase it" do
      deck = deck()
      {:ok, _note} = Decks.put_card_note(deck, "Sol Ring", "fica sempre")

      {:ok, :removed} = Decks.put_card_note(deck, "Sol Ring", "   ")

      assert Decks.card_notes(deck) == []
    end

    test "a review's correction is marked as coming from a review" do
      deck = deck()

      {:ok, note} = Decks.put_card_note(deck, "Cultivate", "fixa cor, não é só rampa", :review)

      assert note.source == :review
    end
  end

  describe "the briefing every consult sends" do
    test "carries what he already said, and says his reading wins" do
      snapshot = Deckex.AnalysisFixture.snapshot([])
      report = Analysis.report(snapshot)

      briefing =
        Briefing.build(report, snapshot, :full,
          card_notes: [
            %Deckex.Decks.CardNote{
              card_name: "Jaheira, Friend of the Forest",
              note: "transforma Food em criatura que tapa por mana"
            }
          ]
        )

      assert briefing =~ "O que o dono já disse sobre cartas deste deck"
      assert briefing =~ "Jaheira, Friend of the Forest"
      assert briefing =~ "transforma Food em criatura que tapa por mana"
      assert briefing =~ "his reading wins"
    end

    test "a deck nobody has corrected carries no such section" do
      snapshot = Deckex.AnalysisFixture.snapshot([])
      report = Analysis.report(snapshot)

      briefing = Briefing.build(report, snapshot, :full, card_notes: [])

      refute briefing =~ "O que o dono já disse"
    end
  end
end
