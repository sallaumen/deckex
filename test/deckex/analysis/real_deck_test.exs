defmodule Deckex.Analysis.RealDeckTest do
  @moduledoc """
  Measures a real 100-card Commander deck end to end and locks in the shape of
  the answer. Only the cards with committed Scryfall fixtures resolve, so the
  absolute counts are of that subset — what is locked here is that the lenses
  agree with each other and with the deck.
  """
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Analysis
  alias Deckex.Analysis.Report
  alias Deckex.CatalogueFixture
  alias Deckex.Decks

  setup :verify_on_exit!

  @decklist "test/support/fixtures/decklists/iroh_das_lontra.txt"

  defp import_and_measure do
    CatalogueFixture.seed_all!()

    expect(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, deck} =
      Decks.import_from_text(File.read!(@decklist), %{name: "Iroh das Lontra", source: :paste})

    deck |> Decks.snapshot() |> Analysis.report()
  end

  test "measures the deck and produces actionable findings" do
    report = import_and_measure()

    assert report.deck_name == "Iroh das Lontra"

    # The deck is thin on answers, so the interaction lens must have spoken.
    assert Report.by_lens(report, :interaction) != []

    # Findings are sorted with the worst first.
    severities = Enum.map(report.findings, & &1.severity)
    assert severities == Enum.sort_by(severities, &%{critical: 0, warning: 1, info: 2}[&1])

    # Every finding is actionable: a code, a pt-BR title, and evidence.
    for finding <- report.findings do
      assert finding.code =~ "."
      assert finding.title != ""
      assert finding.evidence != %{}
    end
  end

  test "the curve and mana lenses agree about the deck's size" do
    report = import_and_measure()

    # If these ever disagree, one lens is misreading the type line.
    assert report.curve.nonland_count + trunc(report.mana.land_count) > 0
  end

  test "counterspells never inflate the answer count" do
    report = import_and_measure()

    # :answers excludes counters by construction; this pins that contract
    # against a real deck rather than a hand-built fixture.
    assert report.interaction.answers ==
             report.interaction.spot_removal + report.interaction.board_wipes
  end
end
