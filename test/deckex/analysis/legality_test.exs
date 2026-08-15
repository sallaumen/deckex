defmodule Deckex.Analysis.LegalityTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Legality
  alias Deckex.AnalysisFixture

  # A basic land is the one card a deck legitimately holds many of, and the
  # rule is read off the type line rather than a list of five names.
  defp basic(name, quantity) do
    AnalysisFixture.entry(name: name, quantity: quantity, type_line: "Basic Land — Forest")
  end

  defp codes(snapshot) do
    snapshot |> Legality.findings(Baselines.default()) |> Enum.map(& &1.code)
  end

  # A hundred cards counting the commander: 1 commander + 99 in the main.
  defp legal_deck(overrides \\ []) do
    main = Keyword.get(overrides, :main, [basic("Forest", 99)])

    AnalysisFixture.snapshot(main,
      commanders: [AnalysisFixture.entry(name: "Iroh, Grand Lotus")],
      color_identity: Keyword.get(overrides, :color_identity, ["G", "R", "U"])
    )
  end

  describe "deck size" do
    test "exactly 100 says nothing" do
      refute "legality.deck_size" in codes(legal_deck())
    end

    # Found on a real deck the day this shipped, sitting at 103.
    test "over 100 is critical, and says by how many" do
      snapshot = legal_deck(main: [basic("Forest", 102)])

      assert [finding] =
               snapshot
               |> Legality.findings(Baselines.default())
               |> Enum.filter(&(&1.code == "legality.deck_size"))

      assert finding.severity == :critical
      assert finding.detail =~ "103 cartas"
      assert finding.detail =~ "3 a mais"
    end

    test "under 100 counts the other way" do
      snapshot = legal_deck(main: [basic("Forest", 90)])

      assert [finding] =
               snapshot
               |> Legality.findings(Baselines.default())
               |> Enum.filter(&(&1.code == "legality.deck_size"))

      assert finding.detail =~ "9 a menos"
    end

    test "the commander counts towards the hundred" do
      assert Legality.measure(legal_deck()).size == 100
    end
  end

  describe "colour identity" do
    test "a card outside the commander's identity is illegal, not merely bad" do
      snapshot =
        legal_deck(
          main: [
            basic("Forest", 98),
            AnalysisFixture.entry(name: "Damnation", color_identity: ["B"])
          ],
          color_identity: ["G", "R", "U"]
        )

      assert "legality.outside_identity" in codes(snapshot)
      assert Legality.measure(snapshot).outside_identity == ["Damnation"]
    end

    # Pasting a list without its commander block is a common import, not a deck
    # in which every card is illegal.
    test "no commander declared, no identity rule" do
      snapshot =
        AnalysisFixture.snapshot(
          [AnalysisFixture.entry(name: "Damnation", color_identity: ["B"], quantity: 100)],
          color_identity: []
        )

      refute "legality.outside_identity" in codes(snapshot)
    end
  end

  describe "singleton" do
    test "a repeated spell is flagged" do
      snapshot =
        legal_deck(
          main: [
            basic("Forest", 97),
            AnalysisFixture.entry(name: "Cultivate", quantity: 2)
          ]
        )

      assert "legality.singleton" in codes(snapshot)
      assert Legality.measure(snapshot).duplicated == ["Cultivate"]
    end

    # Asked of the card, never of a list of names: both exceptions are in the
    # card's own data.
    test "basic lands repeat freely" do
      refute "legality.singleton" in codes(legal_deck())
    end

    test "a card whose text lifts the rule repeats freely" do
      snapshot =
        legal_deck(
          main: [
            basic("Forest", 90),
            AnalysisFixture.entry(
              name: "Relentless Rats",
              quantity: 9,
              oracle_text: "A deck can have any number of cards named Relentless Rats."
            )
          ]
        )

      refute "legality.singleton" in codes(snapshot)
    end
  end

  describe "commander legality" do
    test "a card Scryfall marks illegal is named" do
      snapshot =
        legal_deck(
          main: [
            basic("Forest", 98),
            AnalysisFixture.entry(name: "Black Lotus", commander_legal: false)
          ]
        )

      assert "legality.not_legal" in codes(snapshot)
      assert Legality.measure(snapshot).banned == ["Black Lotus"]
    end
  end

  test "a legal deck produces no findings at all" do
    assert codes(legal_deck()) == []
  end
end
