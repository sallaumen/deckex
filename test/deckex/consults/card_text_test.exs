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

  # The catalogue held twenty fields per card and the briefing sent four. The
  # play rate is the one that stings: it is the format's own count of how many
  # decks run a card, downloaded with every import since the first one, and
  # asking a model whether a card is good while withholding it left "good" a
  # matter of the model's memory.
  describe "what else the catalogue already knew" do
    test "carries the play rate, and glosses what the number means" do
      text =
        briefing([
          AnalysisFixture.entry(name: "Sol Ring", edhrec_rank: 1),
          AnalysisFixture.entry(name: "Prize Pig", edhrec_rank: 5401)
        ])

      assert text =~ "EDHREC #1"
      assert text =~ "a staple of the format"
      assert text =~ "EDHREC #5401"
      assert text =~ "rarely played"
    end

    test "says so plainly when the format has no count for a card" do
      assert briefing([AnalysisFixture.entry(name: "Carta Nova")]) =~ "play rate: unknown"
    end

    # Read one way it deletes exactly the engines that make a deck someone's:
    # Sam, Loyal Attendant sits past rank six thousand and is half a combo.
    test "tells the stage a low rank is not a cut on sight" do
      text = briefing([AnalysisFixture.entry(name: "Sol Ring", edhrec_rank: 1)])

      assert text =~ "evidence, never a verdict"
      assert text =~ "not a cut on"
    end

    # The fragility lens counts blockers by toughness, and the stage answering
    # it could not see a single creature's body.
    test "carries a creature's body" do
      text =
        briefing([
          AnalysisFixture.entry(
            name: "Muralha",
            type_line: "Creature — Wall",
            power: "0",
            toughness: "6"
          )
        ])

      assert text =~ "0/6"
    end

    # Every measurement above is counted from these, and the stage told "0
    # wincons" could neither trust the count nor correct it.
    test "carries the app's own classification of each card" do
      text = briefing([AnalysisFixture.entry(name: "Cultivate", roles: [:ramp, :fixing])])

      assert text =~ "roles: fixing, ramp"
    end

    # One more of these moves the deck a bracket, and the stage adding it had
    # no way to know which card was the one.
    test "marks a Game Changer where it sits" do
      text = briefing([AnalysisFixture.entry(name: "Rhystic Study", game_changer: true)])

      assert text =~ "GAME CHANGER"
    end
  end

  # `oracle_text` on a two-faced card is the FRONT only, and for sixteen cards
  # in the owner's decks that meant the briefing described a different card
  # than the one in the list — a W/B dual land read as mono-white, and a card
  # whose back face reads "noncreature spells you control can't be countered"
  # read as a one-shot counterspell. `card_faces` was in the catalogue the
  # whole time.
  describe "a card with two faces" do
    test "carries both faces, each named" do
      text =
        briefing([
          AnalysisFixture.entry(
            name: "Brightclimb Pathway // Grimclimb Pathway",
            oracle_text: "{T}: Add {W}.",
            card_faces: [
              %{"name" => "Brightclimb Pathway", "oracle_text" => "{T}: Add {W}."},
              %{"name" => "Grimclimb Pathway", "oracle_text" => "{T}: Add {B}."}
            ]
          )
        ])

      assert text =~ "Brightclimb Pathway**"
      assert text =~ "Add {W}"
      assert text =~ "Grimclimb Pathway**"
      assert text =~ "Add {B}"
    end

    # A land that reads as mono-white when it taps for black is a false fact,
    # and a stage counting colour sources acts on it.
    test "the back face is not silently dropped" do
      text =
        briefing([
          AnalysisFixture.entry(
            name: "Malevolent Hermit // Benevolent Geist",
            oracle_text: "Counter target noncreature spell unless its controller pays {3}.",
            card_faces: [
              %{
                "name" => "Malevolent Hermit",
                "oracle_text" =>
                  "Counter target noncreature spell unless its controller pays {3}."
              },
              %{
                "name" => "Benevolent Geist",
                "oracle_text" => "Noncreature spells you control can't be countered."
              }
            ]
          )
        ])

      assert text =~ "can't be countered"
    end

    test "a face with no text of its own does not print an empty heading" do
      text =
        briefing([
          AnalysisFixture.entry(
            name: "Dusk // Dawn",
            oracle_text: "Destroy all creatures with power 3 or greater.",
            card_faces: [
              %{
                "name" => "Dusk",
                "oracle_text" => "Destroy all creatures with power 3 or greater."
              },
              %{"name" => "Dawn", "oracle_text" => ""}
            ]
          )
        ])

      assert text =~ "power 3 or greater"
      refute text =~ "**Dawn**"
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
