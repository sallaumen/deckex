defmodule Deckex.Optimizations.PipelineRegressionTest do
  @moduledoc """
  The whole pipeline, end to end, on a synthetic deck — deliberately NOT the
  reference deck. The reference deck validates; it must never become the shape
  the code fits (spec §8).

  The three real stages, scripted: a plan that proposes nothing, an execution
  with one clean add and one over the ceiling, and a critic that reverts the
  add and then tries to put it back — the flip-flop the engine kills. Every
  stage record is asserted, and the deck page never learns any of it happened.
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

  @recipe [
    %{"kind" => "execucao", "lens" => "execucao", "label" => "Execução"},
    %{"kind" => "critico", "lens" => "critico", "label" => "Crítico"},
    %{"kind" => "critico", "lens" => "critico", "label" => "Segunda leitura"}
  ]

  defp beat(optimization_id, cuts, adds) do
    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
         "leitura" => "Leitura sintética.",
         "diagnosis" => "Diagnóstico sintético.",
         "cuts" => Enum.map(cuts, &%{"card" => &1, "reason" => "corte scriptado"}),
         "adds" => Enum.map(adds, &%{"card" => &1, "reason" => "entrada scriptada"})
       }}
    end)

    {:ok, optimization} = Optimizations.fetch(optimization_id)
    step = Enum.find(optimization.steps, &(&1.status == :running))

    :ok = perform_job(ConsultWorker, %{consult_id: step.consult_id})
    :ok = perform_job(OptimizationAdvanceWorker, %{consult_id: step.consult_id})

    Optimizations.fetch(optimization_id)
  end

  test "an add over the ceiling, a revert, and a dead flip-flop" do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate rhystic_study llanowar_elves))

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n98 Forest\n1 Llanowar Elves", %{
        name: "Deck Sintético",
        source: :paste
      })

    deck =
      deck
      |> Deck.changeset(%{color_identity: ["G", "U"]})
      |> Repo.update!()

    # Rhystic Study is US$ 69.24 — over a R$ 100 ceiling at any sane rate.
    {:ok, optimization} =
      Optimizations.start(deck, %{"ceilings" => %{"card" => 100, "land" => 100}}, @recipe)

    # Stage 1: one clean add, one over the ceiling.
    {:ok, _} = beat(optimization.id, [], ["Cultivate", "Rhystic Study"])

    # Stage 2: reverts stage 1's add — legitimate — and tries the expensive
    # card again, which now trips BOTH the ceiling and nothing else.
    {:ok, _} = beat(optimization.id, ["Cultivate"], [])

    # Stage 3: tries to re-add Cultivate — the flip-flop — and changes nothing
    # else. A card may enter and leave one round once.
    {:ok, _} = beat(optimization.id, [], ["Cultivate"])

    {:ok, final} = Optimizations.fetch(optimization.id)
    [execucao, critico, segunda] = final.steps

    # Stage records, one by one.
    assert [%{"action" => "add", "card" => "Cultivate"}] = execucao.applied
    assert [%{"card" => "Rhystic Study", "problems" => [ceiling_problem]}] = execucao.rejected
    assert ceiling_problem =~ "teto"

    assert [%{"action" => "cut", "card" => "Cultivate"}] = critico.applied

    assert segunda.status == :done
    assert segunda.applied == []
    assert [%{"card" => "Cultivate", "problems" => [flip_problem]}] = segunda.rejected
    assert flip_problem =~ "já entrou e saiu"

    assert final.status == :done
    # Measured, not asserted: the run ended exactly where it started, and the
    # outcome says so rather than claiming success.
    assert final.outcome =~ "sem mudança"

    # The net result: the sandbox ends exactly where it started.
    assert Optimizations.current_list(final) |> Enum.sort_by(& &1["name"]) ==
             Enum.sort_by(final.list_original, & &1["name"])

    # And the real deck never heard about any of it.
    assert Consults.list_for_deck(deck) == []

    names = deck |> Decks.snapshot() |> Map.get(:main) |> Enum.map(& &1.card.name)
    refute "Cultivate" in names
  end
end
