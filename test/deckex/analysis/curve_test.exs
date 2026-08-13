defmodule Deckex.Analysis.CurveTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Curve
  alias Deckex.AnalysisFixture

  defp spells(costs) do
    costs
    |> Enum.with_index()
    |> Enum.map(fn {cmc, i} ->
      AnalysisFixture.entry(name: "Spell #{i}", cmc: to_string(cmc), type_line: "Sorcery")
    end)
    |> AnalysisFixture.snapshot()
  end

  defp codes(snapshot, baselines \\ Baselines.default()) do
    snapshot |> Curve.findings(baselines) |> Enum.map(& &1.code)
  end

  describe "measure/1" do
    test "buckets by converted mana cost, lumping 7 and above" do
      assert %{histogram: %{1 => 1, 2 => 2, 7 => 2}} =
               Curve.measure(spells([1.0, 2.0, 2.0, 7.0, 9.0]))
    end

    test "counts copies, not rows" do
      snapshot =
        AnalysisFixture.snapshot([
          AnalysisFixture.entry(cmc: "2.0", type_line: "Sorcery", quantity: 3)
        ])

      assert %{histogram: %{2 => 3}, nonland_count: 3} = Curve.measure(snapshot)
    end

    test "excludes lands from the curve" do
      snapshot =
        AnalysisFixture.snapshot([
          AnalysisFixture.entry(cmc: "0.0", type_line: "Basic Land — Forest", quantity: 4),
          AnalysisFixture.entry(cmc: "2.0", type_line: "Sorcery")
        ])

      assert %{nonland_count: 1, histogram: histogram} = Curve.measure(snapshot)
      refute Map.has_key?(histogram, 0)
    end

    test "averages over copies" do
      assert %{avg_cmc: 2.0} = Curve.measure(spells([1.0, 3.0]))
    end

    test "an empty deck averages zero rather than dividing by zero" do
      # +0.0 rather than 0.0: since OTP 27 a literal 0.0 pattern matches only
      # positive zero, and the compiler warns about the ambiguity.
      assert %{avg_cmc: +0.0, nonland_count: 0} = Curve.measure(AnalysisFixture.snapshot([]))
    end

    test "counts early plays and late game" do
      assert %{early_plays: 3, late_game: 2} = Curve.measure(spells([1.0, 2.0, 3.0, 5.0, 6.0]))
    end
  end

  describe "findings/2" do
    test "flags a slow deck with no ramp to justify it" do
      assert "curve.too_slow" in codes(spells(List.duplicate(5.0, 20)))
    end

    test "does not flag a slow deck that ramps hard" do
      ramp =
        for i <- 1..12, do: AnalysisFixture.entry(name: "Ramp #{i}", cmc: "2.0", roles: [:ramp])

      slow = for i <- 1..20, do: AnalysisFixture.entry(name: "Big #{i}", cmc: "5.0")

      refute "curve.too_slow" in codes(AnalysisFixture.snapshot(ramp ++ slow))
    end

    test "flags a deck that cannot act before turn four" do
      assert "curve.no_early_plays" in codes(spells(List.duplicate(5.0, 20)))
    end

    test "flags a top-heavy deck" do
      assert "curve.top_heavy" in codes(spells(List.duplicate(2.0, 10) ++ List.duplicate(7.0, 5)))
    end

    test "flags a fast deck with no late game" do
      assert "curve.no_late_game" in codes(spells(List.duplicate(1.0, 30)))
    end

    test "a healthy curve produces no findings" do
      healthy =
        List.duplicate(1.0, 6) ++
          List.duplicate(2.0, 14) ++
          List.duplicate(3.0, 12) ++ List.duplicate(4.0, 8) ++ List.duplicate(5.0, 6)

      assert codes(spells(healthy)) == []
    end

    test "every finding names the cards behind it and its evidence" do
      [finding | _rest] = Curve.findings(spells(List.duplicate(5.0, 20)), Baselines.default())

      assert finding.card_names != []
      assert finding.evidence != %{}
      assert finding.lens == :speed_curve
    end
  end
end
