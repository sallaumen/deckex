defmodule Deckex.Consults.CardTextTest do
  @moduledoc """
  The briefing carries what the cards actually do.

  For most of this app's life it did not. A hundred lines of name, mana cost
  and type line went out, and every model that read one was working from memory
  about the rules text — which is the single cause behind the worst failures
  the owner has hit. A stage cut Jaheira without knowing she turns Food into
  mana creatures. A stage cut Sam, Loyal Attendant — "Creature — Halfling
  Peasant", said the briefing — without knowing she makes Food abilities cost
  {1} less, which is half of an infinite combo with Prize Pig. A stage invented
  Austere Command's modes and the stage after it spent itself undoing the add.

  Every one of those texts was already in the catalogue.
  """
  use ExUnit.Case, async: true

  alias Deckex.Analysis
  alias Deckex.AnalysisFixture
  alias Deckex.Consults.Briefing

  @sam "Activated abilities of Foods you control cost {1} less to activate."
  @pig "{T}: Add one mana of any color."

  defp briefing(entries, opts \\ []) do
    snapshot = AnalysisFixture.snapshot(entries, Keyword.take(opts, [:commanders]))

    Briefing.build(Analysis.report(snapshot), snapshot, :full, opts)
  end

  describe "the decklist" do
    test "carries each card's rules text, not just its type line" do
      text =
        briefing([
          AnalysisFixture.entry(name: "Sam, Loyal Attendant", oracle_text: @sam),
          AnalysisFixture.entry(name: "Prize Pig", oracle_text: @pig)
        ])

      assert text =~ "Sam, Loyal Attendant"
      assert text =~ @sam
      assert text =~ "Prize Pig"
      assert text =~ @pig
    end

    # A combo is two texts read side by side. With only names and type lines no
    # model can see one, which is why "ele não percebe esse combo" was never a
    # question of the model being weak.
    test "puts both halves of an interaction where they can be read together" do
      text =
        briefing([
          AnalysisFixture.entry(name: "Sam, Loyal Attendant", oracle_text: @sam),
          AnalysisFixture.entry(name: "Prize Pig", oracle_text: @pig)
        ])

      assert String.contains?(text, @sam) and String.contains?(text, @pig)
    end

    # Half a card's text is how you produce a *new* misreading, and the long
    # cards are exactly the ones being misread.
    test "does not truncate a long card" do
      long = String.duplicate("Choose one or more — ", 30)

      assert briefing([AnalysisFixture.entry(name: "Austere Command", oracle_text: long)]) =~ long
    end

    test "a card with no text in the catalogue is still listed" do
      text = briefing([AnalysisFixture.entry(name: "Mountain", oracle_text: "")])

      assert text =~ "Mountain"
    end
  end

  describe "the commander" do
    # The one card in play every single game, and the briefing used to name it
    # and stop. Its text is the deck's whole premise.
    test "carries its rules text too" do
      commander =
        AnalysisFixture.entry(name: "Sam, Loyal Attendant", oracle_text: @sam)

      text = briefing([AnalysisFixture.entry(name: "Prize Pig")], commanders: [commander])

      assert text =~ "Commander"
      assert text =~ @sam
    end
  end
end
