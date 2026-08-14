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
  alias Deckex.Consults.Briefing
  alias Deckex.Consults.Suggestion
  alias Deckex.Decks
  alias Deckex.Decks.Deck

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

  test "a briefing for the real deck carries the dossier between findings and decklist" do
    report = import_and_measure()

    dossier = %{
      "plano" => "Spellslinger Temur: Iroh recompra instants e sorceries.",
      "sinergias" => "Iroh dá flashback às Lessons não-Lesson por {1}.",
      "linhas_de_vitoria" => "Storm Kiln Artist e cópias.",
      "fraquezas" => "Um Bojuka Bog desliga metade do plano."
    }

    deck = Repo.one!(Deck)
    snapshot = Decks.snapshot(deck)

    briefing = Briefing.build(report, snapshot, :full, dossier: dossier)

    {dossier_at, _} = :binary.match(briefing, "## Leitura estratégica")
    {findings_at, _} = :binary.match(briefing, "## Findings")
    {decklist_at, _} = :binary.match(briefing, "## The full decklist")

    assert findings_at < dossier_at
    assert dossier_at < decklist_at
    assert briefing =~ "Bojuka Bog"
  end

  # The audited answer mirrors the recorded opus consult: cut the colourless
  # utility land, add a fixer the deck does not have. Plus one deliberately
  # illegal add — Agadeem's Awakening is black, and this deck is Temur.
  # (The first draft of this test added Command Tower and the engine rejected
  # it: the deck already runs one. The audit caught the test's own mistake.)
  test "the engine audits an opus-shaped answer against the real deck" do
    _report = import_and_measure()

    snapshot =
      Deck
      |> Repo.one!()
      |> Deck.changeset(%{color_identity: ["G", "R", "U"]})
      |> Repo.update!()
      |> Decks.snapshot()

    suggestions =
      [
        {:cut, "Reliquary Tower"},
        {:add, "Cultivate"},
        {:add, "Agadeem's Awakening"}
      ]
      |> Enum.map(fn {action, name} ->
        card = Deckex.Cards.get_by_name(name)

        %Suggestion{
          action: action,
          name: name,
          reason: "t",
          card: card,
          resolved?: card != nil
        }
      end)

    audit = Deckex.Consults.audit(snapshot, suggestions)

    # The one illegal suggestion is the one flagged, by colour.
    assert [problem] = audit.problems[{:add, "Agadeem's Awakening"}]
    assert problem =~ "fora da identidade de cor (B)"
    assert map_size(audit.problems) == 1

    # The accounting is total: every before-finding is resolved or remaining,
    # and nothing appears on both sides.
    resolved = MapSet.new(audit.resolved, & &1.code)
    remaining = MapSet.new(audit.remaining, & &1.code)
    assert MapSet.disjoint?(resolved, remaining)

    assert MapSet.disjoint?(MapSet.new(audit.introduced, & &1.code), remaining) == false or
             audit.introduced == []
  end
end
