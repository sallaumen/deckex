defmodule Deckex.Analysis.ConsistencyTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Consistency
  alias Deckex.AnalysisFixture

  defp with_roles(role, n) do
    for i <- 1..n, do: AnalysisFixture.entry(name: "#{role} #{i}", roles: [role])
  end

  defp codes(entries, baselines \\ Baselines.default()) do
    entries
    |> AnalysisFixture.snapshot()
    |> Consistency.findings(baselines)
    |> Enum.map(& &1.code)
  end

  describe "measure/1" do
    test "counts card advantage, tutors, recursion and win conditions" do
      entries =
        with_roles(:draw, 10) ++
          with_roles(:tutor, 3) ++ with_roles(:recursion, 7) ++ with_roles(:wincon, 4)

      assert %{draw: 10, tutors: 3, recursion: 7, wincons: 4} =
               entries |> AnalysisFixture.snapshot() |> Consistency.measure()
    end

    test "counts roles the deck holds exactly one copy of" do
      entries = with_roles(:draw, 10) ++ with_roles(:board_wipe, 1)

      assert %{single_points_of_failure: [:board_wipe]} =
               entries |> AnalysisFixture.snapshot() |> Consistency.measure()
    end
  end

  describe "findings/2" do
    test "flags thin card advantage" do
      assert "consistency.draw_low" in codes(with_roles(:draw, 3))
    end

    test "flags a deck with no identified win condition" do
      assert "consistency.no_wincon" in codes(with_roles(:draw, 10))
    end

    test "flags a role the deck holds exactly one of" do
      entries = with_roles(:draw, 10) ++ with_roles(:wincon, 4) ++ with_roles(:board_wipe, 1)

      assert "consistency.single_point_of_failure" in codes(entries)
    end

    test "a consistent deck produces no findings" do
      entries = with_roles(:draw, 10) ++ with_roles(:wincon, 4) ++ with_roles(:tutor, 3)

      assert codes(entries) == []
    end
  end
end
