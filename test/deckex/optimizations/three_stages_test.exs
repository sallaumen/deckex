defmodule Deckex.Optimizations.ThreeStagesTest do
  @moduledoc """
  The recipe that replaced nine lens stages with three phases.

  The old division was by lens — mana, curve, interaction, consistency, plus
  checkpoints to clean up after them — and that is precisely why the stages
  contradicted each other: each had a partial view and a partial mandate. A
  measured run applied 44 changes and undid 16, and the reverts were *right*;
  the later stages were spending their budget correcting the earlier ones.

  These tests hold the three things the new shape promises: a plan nobody may
  reinterpret, a single author for every change, and a critic answerable to a
  measurement rather than to its own impression.
  """
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Optimizations
  alias Deckex.Workers.ConsultWorker
  alias Deckex.Workers.OptimizationAdvanceWorker

  setup :verify_on_exit!

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate rhystic_study counterspell))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n99 Forest", %{name: "Deck de Fases", source: :paste})

    deck |> Deck.changeset(%{color_identity: ["G", "U"]}) |> Repo.update!()
  end

  defp plan_answer do
    {:ok,
     %{
       "leitura" => "É um deck de rampa verde que não fecha partida.",
       "prioridades" => [
         %{
           "problema" => "Nenhuma win condition",
           "porque_importa" => "O deck rampa e depois não faz nada com a mana.",
           "como_resolver" => "Um fecho que aproveite a mana, tipo um X grande."
         }
       ],
       "nao_mexer" => "A base de terrenos — ela é o motor, não o problema.",
       "plano" => "Rampar até uma ameaça grande.",
       "sinergias" => "Sol Ring acelera tudo.",
       "linhas_de_vitoria" => "Ainda não tem uma.",
       "fraquezas" => "Depende de topar bem."
     }}
  end

  defp change_answer(cuts, adds) do
    {:ok,
     %{
       "leitura" => "Leitura sintética.",
       "veredito" => "Veredito sintético.",
       "diagnosis" => "Diagnóstico sintético.",
       "cuts" => Enum.map(cuts, &%{"card" => &1, "reason" => "corte scriptado"}),
       "adds" => Enum.map(adds, &%{"card" => &1, "reason" => "entrada scriptada"})
     }}
  end

  defp beat(optimization_id, answer) do
    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts -> answer end)

    {:ok, optimization} = Optimizations.fetch(optimization_id)
    step = Enum.find(optimization.steps, &(&1.status == :running))

    assert :ok = perform_job(ConsultWorker, %{consult_id: step.consult_id})
    assert :ok = perform_job(OptimizationAdvanceWorker, %{consult_id: step.consult_id})

    Optimizations.fetch(optimization_id)
  end

  defp stub_scryfall do
    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)
  end

  describe "the plan stage" do
    test "proposes nothing, and the round still moves on" do
      stub_scryfall()
      {:ok, optimization} = Optimizations.start(deck())

      {:ok, planned} = beat(optimization.id, plan_answer())

      [plano, execucao, _critico] = planned.steps
      assert plano.kind == :plano
      assert plano.status == :done
      assert plano.applied == []
      assert execucao.status == :running
    end

    # There is no scout stage any more: the stage that has just read the whole
    # deck to plan the round writes the four dossier fields for almost nothing,
    # and a dossier rewritten every run cannot go stale between runs.
    test "rewrites the deck's dossier on its way past" do
      stub_scryfall()
      deck = deck()
      {:ok, optimization} = Optimizations.start(deck)

      {:ok, _planned} = beat(optimization.id, plan_answer())

      {:ok, fresh} = Decks.fetch_deck(deck.id)
      assert fresh.dossier["sinergias"] == "Sol Ring acelera tudo."
      refute fresh.dossier_stale
      # The planning fields are not dossier fields and must not leak into it.
      refute Map.has_key?(fresh.dossier, "prioridades")
    end

    # A plan summarised is a plan the next stage gets to reinterpret, which is
    # the failure this recipe exists to end.
    test "reaches the stages after it verbatim" do
      stub_scryfall()
      {:ok, optimization} = Optimizations.start(deck())
      {:ok, planned} = beat(optimization.id, plan_answer())

      execucao = Enum.at(planned.steps, 1)
      {:ok, consult} = Consults.fetch(execucao.consult_id)

      assert consult.briefing =~ "O plano desta rodada"
      assert consult.briefing =~ "Nenhuma win condition"
      assert consult.briefing =~ "A base de terrenos"
      assert consult.briefing =~ "Não mexer:"
    end
  end

  describe "the critic" do
    test "is handed what the round broke, by code, rather than asked to notice" do
      stub_scryfall()
      {:ok, optimization} = Optimizations.start(deck())

      {:ok, _planned} = beat(optimization.id, plan_answer())
      {:ok, executed} = beat(optimization.id, change_answer(["Forest"], ["Cultivate"]))

      critico = Enum.at(executed.steps, 2)
      {:ok, consult} = Consults.fetch(critico.consult_id)

      assert consult.briefing =~ "O que a rodada fez, medido pelo motor"
      assert consult.briefing =~ "deck may not end worse than it started"
    end

    test "sees the plan it is judging against" do
      stub_scryfall()
      {:ok, optimization} = Optimizations.start(deck())

      {:ok, _planned} = beat(optimization.id, plan_answer())
      {:ok, executed} = beat(optimization.id, change_answer([], []))

      {:ok, consult} = Consults.fetch(Enum.at(executed.steps, 2).consult_id)

      assert consult.briefing =~ "Nenhuma win condition"
    end
  end

  describe "the verdict" do
    # "Never leave the deck worse" cannot be a sentence in a prompt: a model
    # that believes it improved the deck will say so either way. The engine
    # computes both reports and the run reports the number it found.
    test "states the measured delta rather than claiming success" do
      stub_scryfall()
      {:ok, optimization} = Optimizations.start(deck())

      {:ok, _planned} = beat(optimization.id, plan_answer())
      {:ok, _executed} = beat(optimization.id, change_answer([], []))
      {:ok, final} = beat(optimization.id, change_answer([], []))

      assert final.status == :done
      assert final.outcome =~ "críticos"
      assert {before, now} = Optimizations.criticals_delta(final)
      assert is_integer(before) and is_integer(now)
    end

    test "the effect names what closed, what opened and what is still open" do
      stub_scryfall()
      {:ok, optimization} = Optimizations.start(deck())

      effect = Optimizations.effect(optimization)

      assert %{resolved: [], introduced: [], remaining: [_ | _]} = effect
    end
  end
end
