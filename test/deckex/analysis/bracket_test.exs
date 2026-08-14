defmodule Deckex.Analysis.BracketTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Bracket
  alias Deckex.AnalysisFixture

  defp snap(entries), do: AnalysisFixture.snapshot(entries)

  defp changer(name), do: AnalysisFixture.entry(name: name, game_changer: true)

  describe "floor/1" do
    test "a clean deck may claim bracket 1" do
      assert %Bracket{floor: 1} = Bracket.floor(snap([AnalysisFixture.entry(name: "Forest")]))
    end

    test "one Game Changer puts the floor at 3" do
      bracket = Bracket.floor(snap([changer("Rhystic Study")]))

      assert bracket.floor == 3
      assert bracket.game_changers == ["Rhystic Study"]
    end

    test "three Game Changers is still bracket 3, at its ceiling" do
      bracket = Bracket.floor(snap(Enum.map(~w(A B C), &changer/1)))

      assert bracket.floor == 3
      assert Bracket.game_changer_headroom(bracket) == 0
    end

    test "the fourth Game Changer forces bracket 4" do
      bracket = Bracket.floor(snap(Enum.map(~w(A B C D), &changer/1)))

      assert bracket.floor == 4
      assert Bracket.game_changer_headroom(bracket) == nil
    end

    test "mass land denial forces bracket 4 on its own" do
      entry = AnalysisFixture.entry(name: "Armageddon", roles: [:mass_land_denial])

      assert %Bracket{floor: 4} = Bracket.floor(snap([entry]))
    end

    test "an extra turn forces bracket 4 on its own" do
      entry = AnalysisFixture.entry(name: "Time Warp", roles: [:extra_turn])

      assert %Bracket{floor: 4} = Bracket.floor(snap([entry]))
    end

    # The commander counts: it is in every game, which is the strongest
    # possible reason to count it.
    test "a Game Changer commander counts" do
      snapshot = AnalysisFixture.snapshot([], commanders: [changer("Kinnan")])

      assert %Bracket{floor: 3} = Bracket.floor(snapshot)
    end

    test "the questions it cannot answer are printed, not guessed" do
      bracket = Bracket.floor(snap([AnalysisFixture.entry(name: "Forest")]))

      assert Enum.any?(bracket.open_questions, &(&1 =~ "combo de duas cartas"))
      assert Enum.any?(bracket.open_questions, &(&1 =~ "fecha o jogo"))
    end
  end
end
