defmodule Deckex.Optimizations.AdvanceTest do
  @moduledoc """
  The pipeline's heartbeat: each test scripts real consults through the Oban
  workers with mocked model answers, then reads the stages the run recorded.
  """
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Optimizations
  alias Deckex.Workers.ConsultWorker
  alias Deckex.Workers.OptimizationAdvanceWorker

  setup :verify_on_exit!

  @two_lenses [
    %{"kind" => "lens", "lens" => "mana_ramp", "label" => "Mana"},
    %{"kind" => "lens", "lens" => "speed_curve", "label" => "Early game"}
  ]

  # A hundred cards, because the pipeline now judges the count: a five-card
  # "deck" was a fiction that only worked while nothing checked, and under the
  # balance guard every cut in one moves further from legal.
  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest counterspell cultivate rhystic_study arid_mesa))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n99 Forest", %{name: "Deck do Avanço", source: :paste})

    deck
    |> Deck.changeset(%{color_identity: ["G", "U"]})
    |> Repo.update!()
  end

  defp answer(cuts, adds) do
    {:ok,
     %{
       "leitura" => "Leio um deck de teste.",
       "diagnosis" => "Diagnóstico de teste.",
       "cuts" => Enum.map(cuts, &%{"card" => &1, "reason" => "corte de teste"}),
       "adds" => Enum.map(adds, &%{"card" => &1, "reason" => "entrada de teste"})
     }}
  end

  # Runs the stage's consult and the advance it enqueues — one full heartbeat.
  defp beat(optimization_id) do
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

  test "clean changes are applied and the next stage receives the new list" do
    stub_scryfall()
    {:ok, optimization} = Optimizations.start(deck(), %{}, @two_lenses)

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer([], ["Cultivate"]) end)
    {:ok, after_first} = beat(optimization.id)

    [first, second] = after_first.steps
    assert first.status == :done
    assert [%{"action" => "add", "card" => "Cultivate"}] = first.applied
    assert first.rejected == []

    assert second.status == :running
    assert %{"name" => "Cultivate", "quantity" => 1} in second.list_before
  end

  test "a revert is legitimate disagreement; a second flip is churn and dies" do
    stub_scryfall()

    recipe = @two_lenses ++ [%{"kind" => "lens", "lens" => "interaction", "label" => "Interação"}]
    {:ok, optimization} = Optimizations.start(deck(), %{}, recipe)

    # Stage 1 adds Cultivate; stage 2 cuts it (the revert — allowed); stage 3
    # tries to add it back (the flip-flop — rejected by the engine).
    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer([], ["Cultivate"]) end)
    {:ok, _} = beat(optimization.id)

    expect(Deckex.AI.Mock, :complete, fn prompt, _s, _o ->
      assert prompt =~ "add Cultivate: entrada de teste"
      answer(["Cultivate"], [])
    end)

    {:ok, _} = beat(optimization.id)

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer([], ["Cultivate"]) end)
    {:ok, final} = beat(optimization.id)

    [first, second, third] = final.steps
    assert [%{"card" => "Cultivate", "action" => "add"}] = first.applied
    assert [%{"card" => "Cultivate", "action" => "cut"}] = second.applied

    assert [%{"card" => "Cultivate", "problems" => [problem]}] = third.rejected
    assert problem =~ "já entrou e saiu"
    assert third.applied == []
  end

  test "the keep list and the commander are untouchable" do
    stub_scryfall()

    {:ok, optimization} =
      Optimizations.start(deck(), %{"keep" => ["Sol Ring"]}, @two_lenses)

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer(["Sol Ring"], []) end)
    {:ok, after_first} = beat(optimization.id)

    [first | _] = after_first.steps
    assert [%{"card" => "Sol Ring", "problems" => [problem]}] = first.rejected
    assert problem =~ "lista de proteção"
  end

  test "an add that would break the contract's bracket is refused" do
    stub_scryfall()

    {:ok, optimization} = Optimizations.start(deck(), %{"bracket_max" => 3}, @two_lenses)

    # The count-based guard is proven in audit_test; here we prove the
    # pipeline WIRES the contract through — a mass-land-denial role on the
    # added card must be refused under bracket_max 3.
    {:ok, _roles} =
      Deckex.Cards.set_role_manually(
        Deckex.Cards.get_by_name("Arid Mesa"),
        :mass_land_denial,
        "teste: negação"
      )

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer([], ["Arid Mesa"]) end)
    {:ok, after_first} = beat(optimization.id)

    [first | _] = after_first.steps
    assert [%{"card" => "Arid Mesa", "problems" => problems}] = first.rejected
    assert Enum.any?(problems, &(&1 =~ "Bracket 4, acima do contrato"))
  end

  test "a checkpoint over an unchanged picture is skipped and the run stabilizes" do
    stub_scryfall()

    recipe =
      @two_lenses ++ [%{"kind" => "checkpoint", "lens" => "full", "label" => "Estabilização"}]

    {:ok, optimization} = Optimizations.start(deck(), %{}, recipe)

    expect(Deckex.AI.Mock, :complete, 2, fn _p, _s, _o -> answer([], []) end)
    {:ok, _} = beat(optimization.id)
    {:ok, final} = beat(optimization.id)

    [_first, _second, checkpoint] = final.steps
    assert checkpoint.status == :skipped
    assert final.status == :done
    assert final.outcome == "estabilizou"
    assert final.finished_at != nil
  end

  # A run may not end on a list that cannot go on a table. The recipe here
  # leaves the copy at 101 cards, and the run refuses to finish there: it
  # appends a stage of its own whose only job is the count.
  test "a run that ends off 100 buys a closing stage and lands on it" do
    stub_scryfall()

    recipe = [
      %{"kind" => "lens", "lens" => "mana_ramp", "label" => "Mana"},
      %{"kind" => "checkpoint", "lens" => "full", "label" => "Estabilização"}
    ]

    {:ok, optimization} = Optimizations.start(deck(), %{}, recipe)

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer([], ["Cultivate"]) end)
    {:ok, mid} = beat(optimization.id)
    assert Enum.at(mid.steps, 1).status == :running

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer([], []) end)
    {:ok, after_recipe} = beat(optimization.id)

    # The recipe is spent, the copy is at 101, and the run is still going.
    assert after_recipe.status == :running
    assert closing = List.last(after_recipe.steps)
    assert closing.kind == :balance
    assert closing.label == "Cortar 1 para fechar 100"

    expect(Deckex.AI.Mock, :complete, fn prompt, _s, _o ->
      assert prompt =~ "Cut exactly **1** card(s) and add none"

      answer(["Cultivate"], [])
    end)

    {:ok, final} = beat(optimization.id)

    assert final.status == :done
    assert final.outcome == "completo"
    assert Optimizations.card_count(Optimizations.current_list(final)) == 100
  end

  # The closing stage lands on 100 or it is refused: it has no slack, because
  # landing exactly is the only thing it was bought for.
  test "a closing answer that misses 100 is refused, and the run says where it stopped" do
    stub_scryfall()

    recipe = [%{"kind" => "lens", "lens" => "mana_ramp", "label" => "Mana"}]

    {:ok, optimization} = Optimizations.start(deck(), %{}, recipe)

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer([], ["Cultivate"]) end)
    {:ok, _at_101} = beat(optimization.id)

    # Two closing stages, both answering with nothing: the gap never closes and
    # the run stops buying consults rather than looping forever.
    expect(Deckex.AI.Mock, :complete, 2, fn _p, _s, _o -> answer([], []) end)
    {:ok, _first_close} = beat(optimization.id)
    {:ok, final} = beat(optimization.id)

    assert final.status == :done
    assert final.outcome == "fechou em 101 cartas, não em 100"
    assert Enum.count(final.steps, &(&1.kind == :balance)) == 2
  end

  test "pause persists results and stops the advance; resume continues" do
    stub_scryfall()
    {:ok, optimization} = Optimizations.start(deck(), %{}, @two_lenses)

    {:ok, paused} = Optimizations.pause(optimization)
    step = Enum.find(paused.steps, &(&1.status == :running))

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer([], ["Cultivate"]) end)
    assert :ok = perform_job(ConsultWorker, %{consult_id: step.consult_id})
    assert :ok = perform_job(OptimizationAdvanceWorker, %{consult_id: step.consult_id})

    {:ok, after_pause} = Optimizations.fetch(optimization.id)
    [first, second] = after_pause.steps
    assert first.status == :done
    assert first.applied != []
    assert second.status == :pending

    {:ok, resumed} = Optimizations.resume(after_pause)
    assert Enum.at(resumed.steps, 1).status == :running
  end

  test "a dead consult pauses the run and marks the stage failed" do
    stub_scryfall()
    {:ok, optimization} = Optimizations.start(deck(), %{}, @two_lenses)
    step = Enum.find(optimization.steps, &(&1.status == :running))

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o ->
      {:error, Deckex.Error.new(:ai_unavailable, "cli sumiu")}
    end)

    assert {:cancel, _msg} = perform_job(ConsultWorker, %{consult_id: step.consult_id})

    {:ok, after_failure} = Optimizations.fetch(optimization.id)
    assert after_failure.status == :paused
    assert Enum.at(after_failure.steps, 0).status == :failed
  end

  # The engine's note rides along with the change it is about. A run that spent
  # one of the two exception slots said so once, in a fold thrown away the
  # moment the stage was recorded.
  test "an applied change carries the engine's note about it" do
    stub_scryfall()

    {:ok, _v} = Deckex.Settings.put(:expensive_card_brl, 1)
    {:ok, optimization} = Optimizations.start(deck(), %{}, @two_lenses)

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer([], ["Cultivate"]) end)
    {:ok, run} = beat(optimization.id)

    assert [%{"card" => "Cultivate", "note" => note}] = hd(run.steps).applied
    assert note =~ "carta cara"
  end

  test "a change the engine had nothing to say about carries no note" do
    stub_scryfall()

    {:ok, optimization} = Optimizations.start(deck(), %{}, @two_lenses)

    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer([], ["Cultivate"]) end)
    {:ok, run} = beat(optimization.id)

    assert [%{"card" => "Cultivate", "note" => nil}] = hd(run.steps).applied
  end
end
