defmodule Deckex.Optimizations.RedoTest do
  @moduledoc """
  Redoing a stage rewinds everything after it.

  Stage N's answer is the input to N+1. Recomputing N while keeping what was
  built on it would leave the sandbox describing a history that never happened
  — the one thing this whole feature must never do.
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

  # A floor of sonnet leaves a real ladder to climb: the run starts on sonnet
  # and the redo reaches for fable, which is the whole point of the feature.
  #
  # Cards are seeded first, and that order is load-bearing: a transaction that
  # writes `settings` before `cards` inverts the order every other test takes
  # them in, and two of those deadlock. See the lock-order law in AGENTS.md.
  # `seed!/1` is idempotent within a transaction, so the tests' own `seed!`
  # calls are free after this one.
  setup do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate counterspell))
    {:ok, _} = Deckex.Settings.put(:model_floor, "sonnet")

    :ok
  end

  @recipe [
    %{"kind" => "lens", "lens" => "mana_ramp", "label" => "Mana"},
    %{"kind" => "lens", "lens" => "speed_curve", "label" => "Early game"},
    %{"kind" => "lens", "lens" => "interaction", "label" => "Interação"}
  ]

  defp answer(cuts, adds) do
    %{
      "leitura" => "l",
      "diagnosis" => "d",
      "cuts" => Enum.map(cuts, &%{"card" => &1, "reason" => "corte"}),
      "adds" => Enum.map(adds, &%{"card" => &1, "reason" => "entrada"})
    }
  end

  defp beat(id, cuts, adds) do
    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> {:ok, answer(cuts, adds)} end)

    {:ok, optimization} = Optimizations.fetch(id)
    step = Enum.find(optimization.steps, &(&1.status == :running))

    :ok = perform_job(ConsultWorker, %{consult_id: step.consult_id})
    :ok = perform_job(OptimizationAdvanceWorker, %{consult_id: step.consult_id})

    Optimizations.fetch(id)
  end

  defp run_two_stages do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate counterspell))

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck do Refazer", source: :paste})

    deck = deck |> Deck.changeset(%{color_identity: ["G"]}) |> Repo.update!()

    {:ok, optimization} = Optimizations.start(deck, %{"model" => "sonnet"}, @recipe)
    {:ok, one} = beat(optimization.id, [], ["Cultivate"])
    {:ok, two} = beat(one.id, [], [])
    # All three answered, so the run is at rest — a redo may not race a stage
    # that is still consulting.
    {:ok, done} = beat(two.id, [], [])

    done
  end

  test "it rewinds every stage after the one being redone" do
    optimization = run_two_stages()
    [stage_one, stage_two, _three] = optimization.steps

    assert stage_one.status == :done
    assert stage_two.status == :done

    {:ok, redone} = Optimizations.redo_step(optimization, stage_one.id, "fable")
    [one, two, three] = redone.steps

    # The stage being redone is consulting again, with the chosen model.
    assert one.status == :running
    assert one.model == "fable"

    # Everything after it went back to pending with nothing carried over.
    assert two.status == :pending
    assert two.applied == []
    assert two.rejected == []
    assert two.consult_id == nil
    assert two.list_before == nil
    assert three.status == :pending

    assert redone.status == :running
  end

  test "the discarded answers stay readable" do
    optimization = run_two_stages()
    before_redo = length(Consults.list_all_for_optimization(optimization.id))

    {:ok, _redone} = Optimizations.redo_step(optimization, hd(optimization.steps).id, "fable")

    # Nothing was deleted; a new consult joined them.
    assert length(Consults.list_all_for_optimization(optimization.id)) == before_redo + 1
  end

  test "redoing a finished run puts it back to running and clears the outcome" do
    finished = run_two_stages()

    assert finished.status == :done
    assert finished.outcome

    {:ok, redone} = Optimizations.redo_step(finished, hd(finished.steps).id, "fable")

    assert redone.status == :running
    assert redone.outcome == nil
    assert redone.finished_at == nil
  end

  test "it refuses while a stage is in flight, rather than racing it" do
    finished = run_two_stages()

    # Put one back in flight by redoing it, then try to redo another.
    {:ok, mid_flight} = Optimizations.redo_step(finished, hd(finished.steps).id, "fable")
    assert Enum.any?(mid_flight.steps, &(&1.status == :running))

    assert {:error, error} =
             Optimizations.redo_step(mid_flight, Enum.at(mid_flight.steps, 1).id, "fable")

    assert error.message =~ "consultando agora"
  end

  test "it refuses a model below the floor" do
    finished = run_two_stages()

    assert {:error, error} = Optimizations.redo_step(finished, hd(finished.steps).id, "haiku")
    assert error.message =~ "abaixo do seu piso"
  end

  test "it names the cost before the click" do
    optimization = run_two_stages()

    # Two stages have run past the first one; redoing it discards both.
    assert Optimizations.stages_after(optimization, hd(optimization.steps).id) == 2
  end
end
