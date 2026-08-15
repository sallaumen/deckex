defmodule Deckex.Analysis.MesaTest do
  use Deckex.DataCase, async: true

  alias Deckex.Analysis
  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Mesa
  alias Deckex.Cards
  alias Deckex.CatalogueFixture
  alias Deckex.Decks

  # Rhystic Study taxes, Tergrid steals, Grave Pact forces sacrifices, Humility
  # switches off a whole category — four different ways to spend somebody
  # else's evening.
  defp deck_with(names) do
    CatalogueFixture.seed!(~w(sol_ring forest rhystic_study tergrid grave_pact humility))
    |> Enum.each(&Cards.classify_card/1)

    lines = Enum.map_join(names, "\n", &"1 #{&1}")

    {:ok, deck} =
      Decks.import_from_text("4 Forest\n" <> lines, %{name: "Deck da Mesa", source: :paste})

    Decks.snapshot(deck)
  end

  test "it counts and names what the deck takes from the table" do
    snapshot = deck_with(["Rhystic Study", "Tergrid, God of Fright", "Grave Pact"])

    measure = Mesa.measure(snapshot)

    assert measure.table_time == 3
    assert "Rhystic Study" in measure.cards
    assert measure.by_role[:taxation] == 1
    assert measure.by_role[:theft] == 1
    assert measure.by_role[:forced_sacrifice] == 1
  end

  test "a deck that takes nothing measures zero and says nothing" do
    snapshot = deck_with(["Sol Ring"])

    assert Mesa.measure(snapshot).table_time == 0
    assert Mesa.findings(snapshot, Baselines.default()) == []
  end

  test "past the ceiling it warns, and names every card" do
    snapshot = deck_with(["Rhystic Study", "Tergrid, God of Fright", "Grave Pact", "Humility"])

    baselines = %{Baselines.default() | table_time_max: 2}

    assert [finding] = Mesa.findings(snapshot, baselines)
    assert finding.lens == :mesa
    assert finding.severity == :warning
    assert finding.title =~ "tempo dos outros"
    assert length(finding.card_names) == 4
  end

  test "the report carries the section and the finding" do
    snapshot = deck_with(["Rhystic Study", "Tergrid, God of Fright", "Grave Pact", "Humility"])

    report = Analysis.report(snapshot, %{Baselines.default() | table_time_max: 1})

    assert report.mesa.table_time == 4
    assert Enum.any?(report.findings, &(&1.lens == :mesa))
  end

  test "the table's own clock is a baseline the owner sets" do
    # Not a universal truth: the turn games end at THIS table. Eight is a
    # bracket-3 evening; the owner's pod closes on seven or eight.
    assert Baselines.default().table_close_turn == 8
  end
end
