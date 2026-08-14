defmodule Deckex.Analysis.ReportDiffTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis
  alias Deckex.Analysis.ReportDiff
  alias Deckex.Analysis.Simulation
  alias Deckex.AnalysisFixture

  # Real reports from real snapshots — a diff of hand-built findings would only
  # test the test. A deck with one board wipe fires interaction findings; add
  # nothing and everything "remains", change the deck and the diff must move.
  test "resolved, remaining and introduced are keyed by finding code" do
    before_snap =
      AnalysisFixture.snapshot([
        AnalysisFixture.entry(name: "Blasphemous Act", roles: [:board_wipe, :removal])
      ])

    before_report = Analysis.report(before_snap)
    codes_before = MapSet.new(before_report.findings, & &1.code)

    # Cutting the only wipe must introduce (or keep) the no-wipes finding and
    # cannot resolve it.
    after_snap = Simulation.apply_changes(before_snap, [{:cut, "blasphemous act"}])
    after_report = Analysis.report(after_snap)

    diff = ReportDiff.diff(before_report, after_report)

    resolved_codes = MapSet.new(diff.resolved, & &1.code)
    remaining_codes = MapSet.new(diff.remaining, & &1.code)
    introduced_codes = MapSet.new(diff.introduced, & &1.code)

    # Every before-finding lands in exactly one of resolved/remaining.
    assert MapSet.union(resolved_codes, remaining_codes) == codes_before
    assert MapSet.disjoint?(resolved_codes, remaining_codes)
    # Introduced findings are after-only.
    assert MapSet.disjoint?(introduced_codes, codes_before)
  end

  test "an unchanged deck resolves nothing and introduces nothing" do
    snap = AnalysisFixture.snapshot([AnalysisFixture.entry(name: "Sol Ring")])
    report = Analysis.report(snap)

    diff = ReportDiff.diff(report, report)

    assert diff.resolved == []
    assert diff.introduced == []
    assert length(diff.remaining) == length(report.findings)
  end
end
