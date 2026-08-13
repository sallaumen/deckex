defmodule Deckex.AnalysisTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Analysis
  alias Deckex.Analysis.Report
  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Decks
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  defp seed_catalogue(names) do
    for name <- names do
      attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

      %Card{} |> Card.changeset(attrs) |> Repo.insert!()
    end
  end

  describe "Decks.snapshot/1" do
    test "loads cards, quantities and roles" do
      seed_catalogue(["sol_ring", "forest"])

      {:ok, deck} = Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "T", source: :paste})

      snapshot = Decks.snapshot(deck)

      assert snapshot.deck_name == "T"
      assert length(snapshot.main) == 2

      sol_ring = Enum.find(snapshot.main, &(&1.card.name == "Sol Ring"))
      assert sol_ring.quantity == 1
      assert MapSet.member?(sol_ring.roles, :ramp)

      forest = Enum.find(snapshot.main, &(&1.card.name == "Forest"))
      assert forest.quantity == 4
    end

    test "separates the commander" do
      seed_catalogue(["sol_ring", "natures_lore"])

      {:ok, deck} =
        Decks.import_from_text("Commander\n1 Nature's Lore\n----\n1 Sol Ring", %{
          name: "T",
          source: :paste
        })

      snapshot = Decks.snapshot(deck)

      assert [%{card: %{name: "Nature's Lore"}}] = snapshot.commanders
      assert [%{card: %{name: "Sol Ring"}}] = snapshot.main
    end
  end

  describe "report/2" do
    test "produces every lens and a sorted finding list" do
      seed_catalogue(["sol_ring", "forest"])

      {:ok, deck} = Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "T", source: :paste})

      report = deck |> Decks.snapshot() |> Analysis.report()

      assert %Report{curve: %{}, mana: %{}, interaction: %{}, consistency: %{}} = report
      assert report.deck_name == "T"

      severities = Enum.map(report.findings, & &1.severity)
      assert severities == Enum.sort_by(severities, &%{critical: 0, warning: 1, info: 2}[&1])
    end

    test "counts critical findings" do
      seed_catalogue(["sol_ring"])

      {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})

      assert deck |> Decks.snapshot() |> Analysis.report() |> Report.critical_count() > 0
    end

    test "filters findings by lens" do
      seed_catalogue(["sol_ring"])

      {:ok, deck} = Decks.import_from_text("1 Sol Ring", %{name: "T", source: :paste})
      report = deck |> Decks.snapshot() |> Analysis.report()

      assert Enum.all?(Report.by_lens(report, :interaction), &(&1.lens == :interaction))
    end

    test "is deterministic — the same snapshot yields the same report" do
      seed_catalogue(["sol_ring", "forest"])

      {:ok, deck} = Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "T", source: :paste})
      snapshot = Decks.snapshot(deck)

      assert Analysis.report(snapshot) == Analysis.report(snapshot)
    end
  end
end
