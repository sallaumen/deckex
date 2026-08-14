defmodule Deckex.Analysis.SimulationTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Simulation
  alias Deckex.AnalysisFixture

  defp entry(name, opts \\ []) do
    AnalysisFixture.entry([name: name] ++ opts)
  end

  defp snap(entries) do
    AnalysisFixture.snapshot(entries)
  end

  describe "apply_changes/2" do
    test "a cut removes the entry when it was the last copy" do
      after_snap =
        Simulation.apply_changes(snap([entry("Sol Ring"), entry("Counterspell")]), [
          {:cut, "sol ring"}
        ])

      assert DeckSnapshot.names(after_snap.main) == ["Counterspell"]
    end

    test "a cut decrements when copies remain" do
      after_snap =
        Simulation.apply_changes(snap([entry("Forest", quantity: 4)]), [{:cut, "forest"}])

      assert [%CardEntry{quantity: 3}] = after_snap.main
    end

    test "a cut of a card not in the list is a no-op, not a crash" do
      before_snap = snap([entry("Sol Ring")])

      assert Simulation.apply_changes(before_snap, [{:cut, "carta fantasma"}]) == before_snap
    end

    test "an add appends a new entry" do
      added = entry("Cultivate")

      after_snap = Simulation.apply_changes(snap([entry("Sol Ring")]), [{:add, added}])

      assert DeckSnapshot.names(after_snap.main) == ["Cultivate", "Sol Ring"]
    end

    test "adding a basic land already present bumps its quantity" do
      forest = entry("Forest", quantity: 4, type_line: "Basic Land — Forest")

      after_snap =
        Simulation.apply_changes(snap([forest]), [
          {:add, entry("Forest", type_line: "Basic Land — Forest")}
        ])

      assert [%CardEntry{quantity: 5}] = after_snap.main
    end

    test "adding a singleton card already present is a no-op" do
      before_snap = snap([entry("Sol Ring")])

      after_snap = Simulation.apply_changes(before_snap, [{:add, entry("Sol Ring")}])

      assert [%CardEntry{quantity: 1}] = after_snap.main
    end

    test "commanders are never touched" do
      commander = entry("Iroh, Grand Lotus")

      before_snap = %DeckSnapshot{
        AnalysisFixture.snapshot([entry("Sol Ring")])
        | commanders: [commander]
      }

      after_snap = Simulation.apply_changes(before_snap, [{:cut, "iroh, grand lotus"}])

      assert after_snap.commanders == [commander]
    end
  end
end
