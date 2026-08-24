defmodule Deckex.Decks.CardRulesTest do
  @moduledoc """
  The owner's standing decisions about cards: what he can paste, what the app
  keeps, and what a briefing does with it.

  All of this exists because of one cut. A stage read Sam, Loyal Attendant
  alone, found her ordinary, and removed her — and in his list she is half of
  an infinite combo. The tests here are about the two halves of not having that
  happen again: an order the engine enforces, and a reason the model reads.
  """
  use Deckex.DataCase, async: true

  alias Deckex.Analysis
  alias Deckex.CatalogueFixture
  alias Deckex.Consults.Briefing
  alias Deckex.Decks
  alias Deckex.Decks.CardNote
  alias Deckex.Decks.CardRules

  doctest Deckex.Decks.CardRules

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck das Ordens", source: :paste})

    deck
  end

  describe "what he can paste" do
    test "a decklist line is a card, not a card named 1x" do
      assert [%{name: "Sol Ring"}, %{name: "Forest"}] =
               CardRules.parse("1x Sol Ring\n10 Forest")
    end

    test "the reason comes after a pipe, and is optional" do
      assert [
               %{name: "Sam, Loyal Attendant", note: "combo com o Prize Pig"},
               %{name: "Prize Pig", note: nil}
             ] = CardRules.parse("Sam, Loyal Attendant | combo com o Prize Pig\nPrize Pig")
    end

    # Every other separator anyone would reach for appears inside real card
    # names — commas, colons, apostrophes, dashes, slashes. The pipe does not,
    # which is the whole reason it is the pipe.
    test "a name full of punctuation survives the parse" do
      assert [%{name: "Agadeem's Awakening // Agadeem, the Undercrypt", note: "terra ou bomba"}] =
               CardRules.parse("Agadeem's Awakening // Agadeem, the Undercrypt | terra ou bomba")
    end

    test "blank lines and his own headings are ignored" do
      assert [%{name: "Sol Ring"}] = CardRules.parse("# as que ficam\n\nSol Ring\n\n// fim")
    end

    test "a card written twice is one rule, keeping the first reason" do
      assert [%{name: "Sol Ring", note: "rampa"}] =
               CardRules.parse("Sol Ring | rampa\nSol Ring | mudei de ideia")
    end
  end

  describe "what the app keeps" do
    test "a pasted block becomes rules under one stance" do
      deck = deck()

      {:ok, saved} =
        Decks.put_card_rules(deck, "Sam, Loyal Attendant | faz comida sair de graça", :locked)

      assert [%{card_name: "Sam, Loyal Attendant", stance: :locked}] = saved
      assert Decks.locked_cards(deck) == ["Sam, Loyal Attendant"]
    end

    # He pastes ten cards to lock; the two he had already explained keep their
    # explanations. A paste is an order about a card, not a rewrite of it.
    test "re-pasting without a reason leaves the reason alone" do
      deck = deck()
      {:ok, _first} = Decks.put_card_rules(deck, "Sol Ring | é o motor", :locked)

      {:ok, _again} = Decks.put_card_rules(deck, "Sol Ring", :locked)

      assert [%{note: "é o motor", stance: :locked}] = Decks.card_notes(deck)
    end

    test "changing a card's stance keeps what he wrote about it" do
      deck = deck()
      {:ok, _rule} = Decks.put_card_rules(deck, "Cultivate | fixa cor", :wanted)

      {:ok, promoted} = Decks.put_card_rule(deck, "Cultivate", stance: :locked)

      assert promoted.stance == :locked
      assert promoted.note == "fixa cor"
    end

    # An order does not need a justification to be an order, so erasing the
    # text must not erase the lock. A plain observation with no text left is a
    # row that says nothing, and that one goes.
    test "an empty reason erases an observation but never an order" do
      deck = deck()
      {:ok, _locked} = Decks.put_card_rules(deck, "Sol Ring | é o motor", :locked)
      {:ok, _said} = Decks.put_card_note(deck, "Cultivate", "fixa cor")

      {:ok, kept} = Decks.put_card_rule(deck, "Sol Ring", note: "")
      {:ok, :removed} = Decks.put_card_rule(deck, "Cultivate", note: "  ")

      assert %CardNote{stance: :locked, note: nil} = kept
      assert Enum.map(Decks.card_notes(deck), & &1.card_name) == ["Sol Ring"]
    end

    test "the standing rules come out shaped like a contract" do
      deck = deck()
      {:ok, _locked} = Decks.put_card_rules(deck, "Sol Ring", :locked)
      {:ok, _wanted} = Decks.put_card_rules(deck, "Cultivate", :wanted)
      {:ok, _said} = Decks.put_card_note(deck, "Forest", "tenho muitas")

      assert Decks.standing_rules(deck) == %{
               "keep" => ["Sol Ring"],
               "wanted" => ["Cultivate"]
             }
    end

    test "an order about a card the deck does not have is the one still open" do
      deck = deck()
      {:ok, _locked} = Decks.put_card_rules(deck, "Sol Ring\nPrize Pig", :locked)

      missing = CardRules.missing_from(Decks.locked_cards(deck), ["Sol Ring", "Forest"])

      assert MapSet.to_list(missing) == ["Prize Pig"]
    end
  end

  describe "what a briefing does with it" do
    defp briefing_with(notes) do
      snapshot = Deckex.AnalysisFixture.snapshot([])

      Briefing.build(Analysis.report(snapshot), snapshot, :full, card_notes: notes)
    end

    test "a locked card is stated as unavailable, not as a preference" do
      briefing =
        briefing_with([
          %CardNote{
            card_name: "Sam, Loyal Attendant",
            note: "combo infinito com o Prize Pig",
            stance: :locked
          }
        ])

      assert briefing =~ "Cartas que o dono trancou neste deck"
      assert briefing =~ "Sam, Loyal Attendant"
      assert briefing =~ "combo infinito com o Prize Pig"
      assert briefing =~ "not available to cut"
    end

    # Declining silently is the failure mode: he asked for a card, the round
    # ended, and nothing on the screen said whether anyone considered it.
    test "a wanted card must be answered by name even when refused" do
      briefing = briefing_with([%CardNote{card_name: "Prize Pig", stance: :wanted}])

      assert briefing =~ "Cartas que o dono está pedindo"
      assert briefing =~ "Prize Pig"
      assert briefing =~ "by name"
    end

    test "an observation still wins the reading, and stays out of the orders" do
      briefing =
        briefing_with([
          %CardNote{
            card_name: "Jaheira, Friend of the Forest",
            note: "transforma Food em criatura que tapa por mana",
            stance: :note
          }
        ])

      assert briefing =~ "O que o dono já disse sobre cartas deste deck"
      assert briefing =~ "his reading wins"
      refute briefing =~ "trancou"
      refute briefing =~ "está pedindo"
    end

    test "a deck nobody has decided anything about carries none of it" do
      briefing = briefing_with([])

      refute briefing =~ "O que o dono já disse"
      refute briefing =~ "trancou"
    end
  end
end
