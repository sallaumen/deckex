defmodule Deckex.Optimizations.ReimagineRegressionTest do
  @moduledoc """
  The reimagine pipeline end to end, on a synthetic deck — deliberately NOT the
  reference deck. The reference deck validates; it must never become the shape
  the code fits (spec §8).

  One run: three directions proposed, the run parking to wait, a direction
  chosen with a commander swap, a reconstruction whose salt-violating add is
  refused, and a checkpoint that converges — with the copy closing at exactly
  100 cards and the deck page none the wiser.
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
    %{"kind" => "lens", "lens" => "visao", "label" => "Visões"},
    %{"kind" => "reconstruction", "lens" => "full", "label" => "Reconstrução"},
    %{"kind" => "checkpoint", "lens" => "full", "label" => "Estabilização"}
  ]

  @visoes [
    %{
      "nome" => "Controle azul",
      "arquetipo" => "controle",
      "tema" => "enchantress",
      "tese" => "Responder antes de fechar.",
      "custo" => "Perde velocidade.",
      "cartas_chave" => ["Counterspell"],
      "comandante" => "Baral, Chief of Compliance"
    },
    %{
      "nome" => "Mais rápido",
      "arquetipo" => "aggro",
      "tema" => "tokens",
      "tese" => "Fecha antes.",
      "custo" => "Fica frágil.",
      "cartas_chave" => ["Sol Ring"]
    },
    %{
      "nome" => "Mais consistente",
      "arquetipo" => "midrange",
      "tema" => "toolbox",
      "tese" => "Menos variância.",
      "custo" => "Menos explosão.",
      "cartas_chave" => ["Sol Ring"]
    }
  ]

  defp beat(optimization_id, answer) do
    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> {:ok, answer} end)

    {:ok, optimization} = Optimizations.fetch(optimization_id)
    step = Enum.find(optimization.steps, &(&1.status == :running))

    :ok = perform_job(ConsultWorker, %{consult_id: step.consult_id})
    :ok = perform_job(OptimizationAdvanceWorker, %{consult_id: step.consult_id})

    Optimizations.fetch(optimization_id)
  end

  defp stage(cuts, adds) do
    %{
      "leitura" => "Leitura sintética.",
      "diagnosis" => "Diagnóstico sintético.",
      "cuts" => Enum.map(cuts, &%{"card" => &1, "reason" => "corte scriptado"}),
      "adds" => Enum.map(adds, &%{"card" => &1, "reason" => "entrada scriptada"})
    }
  end

  test "three directions, one chosen, a commander swapped and a tactic refused" do
    CatalogueFixture.seed!(~w(sol_ring island counterspell cultivate baral_chief_of_compliance))

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n99 Island", %{name: "Deck Sintético", source: :paste})

    deck = deck |> Deck.changeset(%{color_identity: ["U"]}) |> Repo.update!()

    {:ok, optimization} =
      Optimizations.start(
        deck,
        %{"mode" => :reimagine, "salt" => %{"counter" => "evitar"}},
        @recipe
      )

    # Stage 1: the visions. The run stops here on its own.
    {:ok, waiting} = beat(optimization.id, %{"visoes" => @visoes})

    assert waiting.status == :awaiting_choice
    assert Enum.at(waiting.steps, 1).status == :pending

    # The owner picks the direction that carries a commander.
    {:ok, chosen} = Optimizations.choose_vision(waiting, 0)

    assert Optimizations.chosen_vision(chosen)["nome"] == "Controle azul"
    assert Optimizations.current_commanders(chosen) == ["Baral, Chief of Compliance"]

    # Stage 2: the reconstruction. Cultivate is out of identity, Counterspell
    # is the tactic the owner avoided — one add survives, and it is neither.
    {:ok, rebuilt} =
      beat(chosen.id, stage([], ["Counterspell", "Cultivate", "Sol Ring"]))

    reconstruction = Enum.at(rebuilt.steps, 1)

    assert reconstruction.status == :done
    assert reconstruction.applied == []

    refusals = Map.new(reconstruction.rejected, &{&1["card"], &1["problems"]})

    assert [counter_problem] = refusals["Counterspell"]
    assert counter_problem =~ "evitar counters"
    assert [identity_problem] = refusals["Cultivate"]
    assert identity_problem =~ "identidade de cor"
    # Sol Ring is already in the list: the singleton rule, still doing its job.
    assert refusals["Sol Ring"]

    # Stage 3: every stage so far applied nothing, so the checkpoint is
    # skipped by the convergence rule and the run ends honestly.
    {:ok, final} = Optimizations.fetch(optimization.id)

    assert final.status == :done
    assert List.last(final.steps).status == :skipped
    assert final.outcome == "estabilizou"

    # The copy is still exactly 100 cards, and the commander swap kept it so.
    assert Optimizations.card_count(Optimizations.current_list(final)) ==
             Optimizations.card_count(final.list_original)

    # The frozen original is untouched; the diff has something to measure from.
    assert final.commanders != Optimizations.current_commanders(final)

    # And the real deck never heard about any of it.
    assert Consults.list_for_deck(deck) == []
    assert Decks.snapshot(deck).commanders == []
  end
end
