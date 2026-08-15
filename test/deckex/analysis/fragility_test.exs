defmodule Deckex.Analysis.FragilityTest do
  @moduledoc """
  The defence rule here was calibrated against a real report and a real
  complaint, and the first version was wrong: it counted eight blockers in a
  deck whose owner says he has nothing to block with. He was right and the
  measure was not — six of those eight were the deck's own engine.
  """
  use Deckex.DataCase, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Fragility
  alias Deckex.Cards
  alias Deckex.CatalogueFixture
  alias Deckex.Decks

  # Seeded ONCE per test, in a single call — two seeds in one test hand back
  # structs whose ids were never written (the deadlock law, AGENTS.md).
  setup do
    ~w(sol_ring forest llanowar_elves storm_kiln_artist young_pyromancer
       goblin_electromancer faithless_looting counterspell cultivate)
    |> CatalogueFixture.seed!()
    |> Enum.each(&Cards.classify_card/1)

    :ok
  end

  defp snapshot(list) do
    {:ok, deck} = Decks.import_from_text(list, %{name: "Deck Frágil", source: :paste})

    Decks.snapshot(deck)
  end

  describe "defence" do
    test "a creature that carries the engine is not counted as a blocker" do
      # Storm-Kiln Artist is 2/2 with ramp; Llanowar Elves is 1/1 with ramp.
      # Neither is available to block even before toughness is considered.
      measured = Fragility.measure(snapshot("4 Forest\n1 Storm-Kiln Artist\n1 Llanowar Elves"))

      assert measured.defence.blockers == 0
    end

    test "it fires when nothing is free to stand in front of an attack" do
      snapshot = snapshot("4 Forest\n1 Storm-Kiln Artist\n1 Young Pyromancer")

      assert [finding] =
               snapshot
               |> Fragility.findings(Baselines.default())
               |> Enum.filter(&(&1.code == "fragility.no_defence"))

      assert finding.severity == :critical
      assert finding.detail =~ "motor do deck"
    end

    test "it stays quiet when the target is met" do
      baselines = %{Baselines.default() | blockers_target: 0}

      assert snapshot("4 Forest\n1 Sol Ring")
             |> Fragility.findings(baselines)
             |> Enum.filter(&(&1.code == "fragility.no_defence")) == []
    end
  end

  describe "the graveyard fault line" do
    test "it counts what needs the yard, and stays quiet otherwise" do
      quiet = Fragility.measure(snapshot("4 Forest\n1 Sol Ring"))
      assert quiet.graveyard.count == 0

      # Faithless Looting is flashback; the rule reads the text, not a role.
      loud = Fragility.measure(snapshot("4 Forest\n1 Faithless Looting"))
      assert loud.graveyard.count == 1
    end
  end

  describe "the board-wipe fault line" do
    test "it only fires when the deck's mana is standing on the battlefield" do
      # Two mana creatures, but not enough bodies to clear the floor.
      measured = Fragility.measure(snapshot("4 Forest\n1 Storm-Kiln Artist\n1 Llanowar Elves"))

      assert measured.board.mana_on_creatures == 2

      assert snapshot("4 Forest\n1 Sol Ring")
             |> Fragility.findings(Baselines.default())
             |> Enum.filter(&(&1.code == "fragility.board_wipe")) == []
    end
  end
end
