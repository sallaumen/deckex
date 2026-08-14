defmodule Deckex.Consults.BriefingTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis
  alias Deckex.AnalysisFixture
  alias Deckex.Consults.Briefing

  @dossier %{
    "plano" => "Spellslinger Temur com Iroh.",
    "sinergias" => "Iroh dá flashback às Lessons.",
    "linhas_de_vitoria" => "Storm Kiln Artist.",
    "fraquezas" => "Cemitério é tudo."
  }

  # One snapshot shared by report and build — a briefing whose report was
  # measured from a different snapshot asserts nothing.
  defp build(lens, opts) do
    snap = AnalysisFixture.snapshot([AnalysisFixture.entry(name: "Sol Ring")])

    Briefing.build(Analysis.report(snap), snap, lens, opts)
  end

  describe "the dossier in the briefing" do
    test "a dossier lands between the findings and the decklist" do
      briefing = build(:full, dossier: @dossier)

      assert briefing =~ "## Leitura estratégica (dossiê do deck)"
      assert briefing =~ "Iroh dá flashback às Lessons."

      dossier_at = position(briefing, "## Leitura estratégica")
      assert dossier_at > position(briefing, "## Findings")
      assert dossier_at < position(briefing, "## The full decklist")
    end

    test "no dossier, no block — everything else intact" do
      briefing = build(:full, [])

      refute briefing =~ "Leitura estratégica"
      assert briefing =~ "## Measurements"
    end

    test "a stale dossier says so" do
      briefing = build(:full, dossier: @dossier, dossier_stale: true)

      assert briefing =~ "the deck has changed since this dossier was written"
    end

    test "with a dossier, the rules demand leitura first and out-loud disagreement" do
      briefing = build(:full, dossier: @dossier)

      assert briefing =~ "Write `leitura` first"
      assert briefing =~ "confronted with the dossier above"
    end

    test "without a dossier, the leitura rule stands but points at no dossier" do
      briefing = build(:full, [])

      assert briefing =~ "Write `leitura` first"
      refute briefing =~ "confronted with the dossier above"
    end
  end

  describe "the scout's briefing" do
    test "the scout is told to read, not to fix" do
      briefing = build(:scout, [])

      assert briefing =~ "Do not propose any change"
      assert briefing =~ "scout, not the consultant"
      refute briefing =~ "**cut**"
    end

    test "the scout never receives a dossier, even when one is passed" do
      briefing = build(:scout, dossier: @dossier)

      refute briefing =~ "Leitura estratégica"
    end

    test "the scout still answers in pt-BR with untranslated card names" do
      briefing = build(:scout, [])

      assert briefing =~ "Portuguese (pt-BR)"
      assert briefing =~ "never translate a card name"
    end
  end

  defp position(string, marker) do
    {at, _len} = :binary.match(string, marker)
    at
  end

  describe "the bracket in the briefing" do
    defp with_changers(count) do
      changers = for i <- 1..count, do: AnalysisFixture.entry(name: "GC#{i}", game_changer: true)
      snap = AnalysisFixture.snapshot(changers)

      Briefing.build(Analysis.report(snap), snap, :full, [])
    end

    test "a clean deck is told its floor is bracket 1" do
      assert build(:full, []) =~ "Measured floor: **Bracket 1**"
    end

    # The headroom line is the whole point: every consult run against the
    # reference deck suggested a fourth Game Changer, and nothing said so.
    test "a deck at the ceiling is warned that one more moves it" do
      briefing = with_changers(3)

      assert briefing =~ "bracket 3 ceiling of 3 Game Changers"
      assert briefing =~ "moves it to bracket 4"
    end

    test "a deck with room is told how much" do
      assert with_changers(1) =~ "room for 2 more Game Changer"
    end

    test "a deck already past the ceiling is told restrictions no longer apply" do
      assert with_changers(4) =~ "Game Changers are unrestricted"
    end
  end

  describe "the rules learned from a real answer" do
    # A model once declined to suggest Underworld Breach believing it banned
    # in Commander; Scryfall says legal. A decline leaves no row for the audit
    # to check, so the prompt has to prevent it at the source.
    test "the model is told not to guess at legality" do
      briefing = build(:full, [])

      assert briefing =~ "Never guess at legality or bans"
      assert briefing =~ "suggested and verified"
    end
  end
end
