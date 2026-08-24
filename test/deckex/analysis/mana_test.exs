defmodule Deckex.Analysis.ManaTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Mana
  alias Deckex.AnalysisFixture

  # `opts` comes FIRST: AnalysisFixture reads with Keyword.get, which returns the
  # first occurrence, so an override has to precede the default it replaces.
  defp land(name, opts) do
    AnalysisFixture.entry(opts ++ [name: name, type_line: "Land", cmc: "0.0", mana_cost: nil])
  end

  defp codes(snapshot, baselines \\ Baselines.default()) do
    snapshot |> Mana.findings(baselines) |> Enum.map(& &1.code)
  end

  describe "measure/2 land counting" do
    test "counts land copies" do
      snapshot = AnalysisFixture.snapshot([land("Forest", quantity: 10)])

      assert %{land_count: 10.0} = Mana.measure(snapshot, Baselines.default())
    end

    test "an MDFC land back counts as half a land" do
      snapshot =
        AnalysisFixture.snapshot([
          land("Forest", quantity: 10),
          AnalysisFixture.entry(name: "Silundi Vision", type_line: "Instant // Land")
        ])

      assert %{land_count: 10.5, mdfc_lands: 1} = Mana.measure(snapshot, Baselines.default())
    end
  end

  describe "land_target/2" do
    test "starts at the baseline for an average deck" do
      spells = for i <- 1..30, do: AnalysisFixture.entry(name: "S#{i}", cmc: "3.0")

      assert Mana.land_target(AnalysisFixture.snapshot(spells), Baselines.default()) == 36
    end

    test "rises with average cost" do
      spells = for i <- 1..30, do: AnalysisFixture.entry(name: "S#{i}", cmc: "4.5")

      assert Mana.land_target(AnalysisFixture.snapshot(spells), Baselines.default()) > 36
    end

    test "falls as ramp piles up" do
      ramp = for i <- 1..25, do: AnalysisFixture.entry(name: "R#{i}", cmc: "2.0", roles: [:ramp])

      assert Mana.land_target(AnalysisFixture.snapshot(ramp), Baselines.default()) < 36
    end

    test "never leaves the rails" do
      b = Baselines.default()
      huge = for i <- 1..40, do: AnalysisFixture.entry(name: "S#{i}", cmc: "9.0")

      assert Mana.land_target(AnalysisFixture.snapshot(huge), b) <= b.land_max
    end
  end

  describe "measure/2 colour sources" do
    test "counts sources per colour, lands and rocks alike" do
      snapshot =
        AnalysisFixture.snapshot(
          [
            land("Forest", quantity: 8, produced_mana: ["G"]),
            AnalysisFixture.entry(name: "Rock", type_line: "Artifact", produced_mana: ["G"])
          ],
          color_identity: ["G"]
        )

      assert %{colors: %{"G" => %{sources: 9}}} = Mana.measure(snapshot, Baselines.default())
    end

    test "records the heaviest pip demand per colour" do
      snapshot =
        AnalysisFixture.snapshot(
          [
            AnalysisFixture.entry(name: "Duplo", mana_cost: "{B}{B}", cmc: "2.0"),
            AnalysisFixture.entry(name: "Simples", mana_cost: "{1}{B}", cmc: "2.0")
          ],
          color_identity: ["B"]
        )

      assert %{colors: %{"B" => %{max_pips: 2, target: 25}}} =
               Mana.measure(snapshot, Baselines.default())
    end

    test "a fetchland counts as a source for the colours it can actually find" do
      # Arid Mesa fetches Mountain or Plains. In a Temur deck only the Mountain
      # half is reachable, so it is a red source and nothing else. Scryfall
      # reports produced_mana: [] for every fetchland, so a naive count reads
      # eight of them as eight dead cards.
      arid_mesa =
        land("Arid Mesa",
          oracle_text:
            "{T}, Pay 1 life, Sacrifice this land: Search your library for a Mountain or Plains card, put it onto the battlefield, then shuffle."
        )

      snapshot = AnalysisFixture.snapshot([arid_mesa], color_identity: ["G", "R", "U"])

      assert %{colors: colors} = Mana.measure(snapshot, Baselines.default())
      assert colors["R"].sources == 1
      assert colors["G"].sources == 0
      assert colors["U"].sources == 0
    end

    test "a fetchland that finds two relevant types counts for both" do
      misty =
        land("Misty Rainforest",
          oracle_text:
            "{T}, Pay 1 life, Sacrifice this land: Search your library for a Forest or Island card, put it onto the battlefield, then shuffle."
        )

      snapshot = AnalysisFixture.snapshot([misty], color_identity: ["G", "R", "U"])

      assert %{colors: colors} = Mana.measure(snapshot, Baselines.default())
      assert colors["G"].sources == 1
      assert colors["U"].sources == 1
      assert colors["R"].sources == 0
    end

    test "a generic basic-land fetcher counts for every colour the deck plays" do
      wilds =
        land("Evolving Wilds",
          oracle_text:
            "{T}, Sacrifice this land: Search your library for a basic land card, put it onto the battlefield tapped, then shuffle."
        )

      snapshot = AnalysisFixture.snapshot([wilds], color_identity: ["G", "U"])

      assert %{colors: colors} = Mana.measure(snapshot, Baselines.default())
      assert colors["G"].sources == 1
      assert colors["U"].sources == 1
    end

    test "counts the fetchlands separately so the number is auditable" do
      arid_mesa =
        land("Arid Mesa",
          oracle_text:
            "Search your library for a Mountain or Plains card, put it onto the battlefield"
        )

      snapshot = AnalysisFixture.snapshot([arid_mesa], color_identity: ["R"])

      assert %{fetchlands: 1} = Mana.measure(snapshot, Baselines.default())
    end

    test "only reports colours in the deck's identity" do
      snapshot =
        AnalysisFixture.snapshot([land("Forest", produced_mana: ["G"])], color_identity: ["G"])

      assert %{colors: colors} = Mana.measure(snapshot, Baselines.default())
      assert Map.keys(colors) == ["G"]
    end
  end

  describe "findings/2" do
    test "flags a colour with fewer sources than its pips demand" do
      # Eight cards wanting {B}{B} behind twelve black sources — the classic.
      demanding =
        for i <- 1..8,
            do: AnalysisFixture.entry(name: "Preta #{i}", mana_cost: "{B}{B}", cmc: "2.0")

      snapshot =
        AnalysisFixture.snapshot(
          [land("Swamp", quantity: 12, produced_mana: ["B"]) | demanding],
          color_identity: ["B"]
        )

      assert "mana.color_starved" in codes(snapshot)
    end

    test "does not flag a colour with plenty of sources" do
      demanding =
        for i <- 1..8,
            do: AnalysisFixture.entry(name: "Preta #{i}", mana_cost: "{B}{B}", cmc: "2.0")

      snapshot =
        AnalysisFixture.snapshot(
          [land("Swamp", quantity: 30, produced_mana: ["B"]) | demanding],
          color_identity: ["B"]
        )

      refute "mana.color_starved" in codes(snapshot)
    end

    test "flags too few lands" do
      spells = for i <- 1..60, do: AnalysisFixture.entry(name: "S#{i}", cmc: "3.0")
      snapshot = AnalysisFixture.snapshot([land("Forest", quantity: 20) | spells])

      assert "mana.land_count_low" in codes(snapshot)
    end

    test "flags too many lands" do
      spells = for i <- 1..30, do: AnalysisFixture.entry(name: "S#{i}", cmc: "2.0")
      snapshot = AnalysisFixture.snapshot([land("Forest", quantity: 50) | spells])

      assert "mana.land_count_high" in codes(snapshot)
    end

    test "flags thin ramp" do
      spells = for i <- 1..60, do: AnalysisFixture.entry(name: "S#{i}", cmc: "3.0")

      assert "mana.ramp_low" in codes(AnalysisFixture.snapshot(spells))
    end

    test "flags ramp that is all too expensive to matter" do
      ramp = for i <- 1..12, do: AnalysisFixture.entry(name: "R#{i}", cmc: "5.0", roles: [:ramp])

      assert "mana.ramp_too_slow" in codes(AnalysisFixture.snapshot(ramp))
    end

    test "flags a mana base that enters tapped too often" do
      snapshot =
        AnalysisFixture.snapshot([
          land("Tapada", quantity: 20, oracle_text: "This land enters tapped."),
          land("Reta", quantity: 10)
        ])

      assert "mana.tapland_heavy" in codes(snapshot)
    end

    test "every finding carries evidence and belongs to the mana lens" do
      spells = for i <- 1..60, do: AnalysisFixture.entry(name: "S#{i}", cmc: "3.0")

      for finding <- Mana.findings(AnalysisFixture.snapshot(spells), Baselines.default()) do
        assert finding.evidence != %{}
        assert finding.lens == :mana_ramp
      end
    end
  end

  # The real deck this came from: three shocklands, three fastlands, two
  # battlebond lands, a checkland and a slowland — ten lands flagged as slow,
  # not one of them unconditional. The stage spent its answer arguing the
  # point, correctly, and the owner paid for the paragraph.
  describe "the conditions on the clause" do
    defp base(entries), do: AnalysisFixture.snapshot(entries ++ [land("Reta", quantity: 26)])

    test "a shockland is not a tapland — it is untapped for two life" do
      snapshot =
        base([
          land("Steam Vents",
            quantity: 10,
            oracle_text:
              "As this land enters, you may pay 2 life. If you don't, it enters tapped."
          )
        ])

      assert %{taplands: 0, taplands_conditional: 10} =
               Mana.measure(snapshot, Baselines.default())
    end

    test "a battlebond land in Commander is a dual, and weighs nothing" do
      snapshot =
        base([
          land("Sea of Clouds",
            quantity: 10,
            oracle_text: "This land enters tapped unless you have two or more opponents."
          )
        ])

      measured = Mana.measure(snapshot, Baselines.default())

      assert %{taplands: 0, taplands_conditional: 0, tapland_share: +0.0} = measured
      refute "mana.tapland_heavy" in codes(snapshot)
    end

    test "a fastland counts half, so a base of them alone does not trip the finding" do
      snapshot =
        base([
          land("Seachrome Coast",
            quantity: 10,
            oracle_text: "This land enters tapped unless you control two or fewer other lands."
          )
        ])

      assert %{taplands: 0, taplands_conditional: 10} =
               Mana.measure(snapshot, Baselines.default())

      refute "mana.tapland_heavy" in codes(snapshot)
    end

    test "an unconditional tapland still counts whole, and still trips it" do
      snapshot =
        base([land("Raugrin Triome", quantity: 10, oracle_text: "This land enters tapped.")])

      assert %{taplands: 10, taplands_conditional: 0} =
               Mana.measure(snapshot, Baselines.default())

      assert "mana.tapland_heavy" in codes(snapshot)
    end

    # Naming a battlebond land as evidence of slowness is how a stage ends up
    # arguing with the finding instead of working it.
    test "the finding names only the lands it counted" do
      snapshot =
        AnalysisFixture.snapshot([
          land("Raugrin Triome", quantity: 12, oracle_text: "This land enters tapped."),
          land("Sea of Clouds",
            quantity: 4,
            oracle_text: "This land enters tapped unless you have two or more opponents."
          ),
          land("Reta", quantity: 10)
        ])

      [finding] =
        snapshot
        |> Mana.findings(Baselines.default())
        |> Enum.filter(&(&1.code == "mana.tapland_heavy"))

      assert "Raugrin Triome" in finding.card_names
      refute "Sea of Clouds" in finding.card_names
    end
  end
end
