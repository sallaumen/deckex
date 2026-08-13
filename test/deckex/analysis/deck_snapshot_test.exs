defmodule Deckex.Analysis.DeckSnapshotTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.AnalysisFixture

  describe "CardEntry" do
    test "reads cmc as a float" do
      assert CardEntry.cmc(AnalysisFixture.entry(cmc: "3.0")) == 3.0
    end

    test "reads the front face type" do
      entry = AnalysisFixture.entry(type_line: "Sorcery // Land")

      assert CardEntry.front_type(entry) == "Sorcery"
      assert CardEntry.back_type(entry) == "Land"
    end

    test "a plain land is a land" do
      assert CardEntry.land?(AnalysisFixture.entry(type_line: "Basic Land — Forest"))
    end

    test "an MDFC whose front is a spell is not a land, but its back is" do
      entry = AnalysisFixture.entry(type_line: "Sorcery // Land")

      refute CardEntry.land?(entry)
      assert CardEntry.mdfc_land?(entry)
    end

    test "a plain land is not an MDFC land" do
      refute CardEntry.mdfc_land?(AnalysisFixture.entry(type_line: "Land"))
    end

    test "counts coloured pips in the mana cost" do
      entry = AnalysisFixture.entry(mana_cost: "{X}{B}{B}{B}")

      assert CardEntry.pips(entry, "B") == 3
      assert CardEntry.pips(entry, "G") == 0
    end

    test "a card with no mana cost has no pips" do
      assert CardEntry.pips(AnalysisFixture.entry(mana_cost: nil), "G") == 0
    end

    test "knows its roles" do
      entry = AnalysisFixture.entry(roles: [:ramp, :fixing])

      assert CardEntry.has_role?(entry, :ramp)
      refute CardEntry.has_role?(entry, :counter)
    end

    test "knows instant speed" do
      assert CardEntry.instant?(AnalysisFixture.entry(type_line: "Instant"))
      refute CardEntry.instant?(AnalysisFixture.entry(type_line: "Sorcery"))
    end
  end

  describe "DeckSnapshot" do
    setup do
      snapshot =
        AnalysisFixture.snapshot([
          AnalysisFixture.entry(name: "Forest", type_line: "Basic Land — Forest", quantity: 4),
          AnalysisFixture.entry(name: "Sol Ring", type_line: "Artifact", roles: [:ramp]),
          AnalysisFixture.entry(name: "Silundi Vision", type_line: "Instant // Land")
        ])

      %{snapshot: snapshot}
    end

    test "separates lands from nonlands by the front face", %{snapshot: snapshot} do
      assert snapshot |> DeckSnapshot.lands() |> Enum.map(& &1.card.name) == ["Forest"]

      assert snapshot |> DeckSnapshot.nonlands() |> Enum.map(& &1.card.name) |> Enum.sort() ==
               ["Silundi Vision", "Sol Ring"]
    end

    test "counts by quantity, not by row", %{snapshot: snapshot} do
      assert snapshot |> DeckSnapshot.lands() |> DeckSnapshot.count() == 4
    end

    test "finds the MDFC lands", %{snapshot: snapshot} do
      assert snapshot |> DeckSnapshot.mdfc_lands() |> Enum.map(& &1.card.name) ==
               ["Silundi Vision"]
    end

    test "filters by role", %{snapshot: snapshot} do
      ramp = snapshot |> DeckSnapshot.nonlands() |> DeckSnapshot.with_role(:ramp)

      assert Enum.map(ramp, & &1.card.name) == ["Sol Ring"]
    end

    test "names entries, sorted", %{snapshot: snapshot} do
      assert snapshot |> DeckSnapshot.nonlands() |> DeckSnapshot.names() ==
               ["Silundi Vision", "Sol Ring"]
    end
  end

  describe "Baselines" do
    test "ships the documented Commander defaults" do
      b = Baselines.default()

      assert b.land_base == 36
      assert b.avg_cmc_high == 3.5
      assert b.ramp_target == 10
      assert b.ramp_cheap_target == 4
      assert b.interaction_floor == 5
      assert b.board_wipe_target == 2
      assert b.sources_double_pip == 25
    end
  end
end
