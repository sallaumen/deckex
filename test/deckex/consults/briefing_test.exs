defmodule Deckex.Consults.BriefingTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis
  alias Deckex.AnalysisFixture
  alias Deckex.Consults
  alias Deckex.Consults.Briefing
  alias Deckex.Consults.Consult

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

  # Twice in one afternoon a rule meant for everyone was written into one
  # branch, and both times the lenses that needed it most were the ones that
  # missed it. Walking every lens is cheaper than remembering.
  describe "what every lens must carry" do
    test "the universal rules reach every lens that proposes changes" do
      universal = [
        "colour identity",
        "Commander is singleton",
        "Flexible removal, not hate cards",
        "Never guess at legality"
      ]

      for lens <- Consult.lenses(), Consults.changes_deck?(lens), rule <- universal do
        assert build(lens, []) =~ rule, "#{lens} não recebeu: #{rule}"
      end
    end

    test "every lens is shown the deck, its measurements and its list" do
      for lens <- Consult.lenses() do
        briefing = build(lens, [])

        assert briefing =~ "## The deck", "#{lens} sem o bloco do deck"
        assert briefing =~ "## Measurements", "#{lens} sem medições"
        assert briefing =~ "## The full decklist", "#{lens} sem a decklist"
      end
    end
  end

  describe "which findings a lens is shown" do
    # This was inverted and cost a real run: :visao — the stage that sets the
    # direction nine stages then execute — was told "the deck passed every
    # lens" about a deck with two criticals.
    test "a whole-deck lens sees every finding" do
      for lens <- [:visao, :upgrade, :budget, :matchup, :alinhamento, :full] do
        briefing = build(lens, [])

        refute briefing =~ "passed every lens",
               "#{lens} recebeu 'nenhum achado' num deck que tem achados"
      end
    end

    test "a narrow lens still sees only its own slice" do
      briefing = build(:mana_ramp, [])

      assert briefing =~ "mana."
      refute briefing =~ "interaction."
    end

    # A universal rule belongs with the universal rules. This one started in
    # the fallback task block, so the lenses that most needed it — visao,
    # upgrade, budget, matchup — were the ones that never saw it.
    test "every lens is told to prefer flexible answers" do
      for lens <- [:visao, :upgrade, :budget, :matchup, :full, :interaction] do
        assert build(lens, []) =~ "Flexible removal, not hate cards",
               "#{lens} não recebeu a regra"
      end
    end

    test "a whole-deck lens is shown the table and fragility sections" do
      briefing = build(:visao, [])

      assert briefing =~ "### mesa"
      assert briefing =~ "### fragility"
    end
  end

  describe "the optimization block" do
    @optimization %{
      contract: %{
        "bracket_max" => 3,
        "ceilings" => %{"card" => 800, "land" => 200},
        "keep" => ["Sol Ring"],
        "notes" => "mantenha o tema de lontras"
      },
      changelog: [
        %{
          label: "Mana",
          applied: [%{"action" => "add", "card" => "Cultivate", "reason" => "fecha o gap de G"}],
          rejected: [
            %{
              "action" => "add",
              "card" => "Cyclonic Rift",
              "reason" => "varredura",
              "problems" => ["é Game Changer — seria o 4º"]
            }
          ]
        }
      ],
      stage_kind: :checkpoint,
      card_count: 98
    }

    test "the reconstruction stage is told it has more room than the others" do
      briefing = build(:full, optimization: %{@optimization | stage_kind: :reconstruction})

      assert briefing =~ "reconstruction"
      assert briefing =~ "more room here than any other stage"
    end

    test "the salt contract states what is a rule and what is a wish" do
      salted =
        put_in(@optimization.contract["salt"], %{"stax" => "evitar", "counter" => "quero"})

      briefing = build(:full, optimization: salted)

      assert briefing =~ "Do NOT propose: stax / prisão"
      assert briefing =~ "actively wants more of: counters"
    end

    test "with a direction chosen, the briefing names it as the target" do
      with_vision =
        put_in(@optimization.contract["visao"], %{
          "nome" => "Mais rápido",
          "tese" => "Fecha antes.",
          "custo" => "Fica frágil."
        })

      briefing = build(:full, optimization: with_vision)

      assert briefing =~ "A direção escolhida: Mais rápido"
      assert briefing =~ "context, not the goal"
    end

    test "alinhamento measures against the vision when there is one, the dossier otherwise" do
      with_vision =
        put_in(@optimization.contract["visao"], %{
          "nome" => "Mais rápido",
          "tese" => "t",
          "custo" => "c"
        })

      assert build(:alinhamento, optimization: with_vision) =~
               "**Mais rápido** — is the reference"

      assert build(:alinhamento, optimization: @optimization) =~
               "dossier above is the **fixed reference**"
    end

    test "the copy's card count lands with its direction" do
      briefing = build(:full, optimization: @optimization)

      assert briefing =~ "The copy has **98 cards**"
      assert briefing =~ "It is 2 short"

      balanced = build(:full, optimization: %{@optimization | card_count: 100})
      assert balanced =~ "Keep adds and cuts balanced"

      over = build(:full, optimization: %{@optimization | card_count: 101})
      assert over =~ "It is 1 over"
    end

    test "the contract, the changelog and the flip rule all land" do
      briefing = build(:full, optimization: @optimization)

      assert briefing =~ "## Otimização em andamento"
      assert briefing =~ "Maximum bracket: **3**"
      assert briefing =~ "Protected cards (never cut): Sol Ring"
      assert briefing =~ "mantenha o tema de lontras"
      assert briefing =~ "add Cultivate: fecha o gap de G"
      assert briefing =~ "REJECTED add Cyclonic Rift"
      assert briefing =~ "enter and leave this optimization once"
    end

    test "a checkpoint is invited to revert; a validation is told to test" do
      checkpoint = build(:full, optimization: @optimization)
      assert checkpoint =~ "stabilization checkpoint"

      validation = build(:full, optimization: %{@optimization | stage_kind: :validation})
      assert validation =~ "find what the tuning missed"
    end

    test "outside a pipeline there is no block at all" do
      refute build(:full, []) =~ "Otimização em andamento"
    end
  end

  describe "the alinhamento and multi-matchup tasks" do
    test "alinhamento treats the dossier as the fixed reference" do
      briefing = build(:alinhamento, dossier: @dossier)

      assert briefing =~ "fixed reference"
      assert briefing =~ "If nothing drifted, say so and propose nothing"
    end

    test "matchup accepts a list of targets" do
      briefing = build(:matchup, against: ["um aggro rápido", "um controle pesado"])

      assert briefing =~ "um aggro rápido; um controle pesado"
    end
  end
end
