defmodule Deckex.Optimizations.OptimizationTest do
  use Deckex.DataCase, async: true

  alias Deckex.Consults.Consult
  alias Deckex.Optimizations.OptimizationQuery

  test "an optimization and its steps round-trip every field" do
    optimization = insert(:optimization)
    step = insert(:optimization_step, optimization: optimization)

    fetched = OptimizationQuery.get(optimization.id)

    assert fetched.status == :running
    assert fetched.contract["ceilings"]["land"] == 200
    assert [%{position: 1, kind: :lens, lens: "mana_ramp"}] = fetched.steps
    assert step.feedback == %{}
  end

  test "steps are unique per position within a run" do
    optimization = insert(:optimization)
    insert(:optimization_step, optimization: optimization, position: 1)

    assert_raise Ecto.ConstraintError, fn ->
      insert(:optimization_step, optimization: optimization, position: 1)
    end
  end

  test "a consult can be tagged with the run it belongs to" do
    optimization = insert(:optimization)
    consult = insert(:consult, optimization_id: optimization.id)

    assert %Consult{optimization_id: tagged} = Repo.get(Consult, consult.id)
    assert tagged == optimization.id
  end

  test "running_for_deck sees running and paused, not finished" do
    optimization = insert(:optimization, status: :paused)

    assert %{id: found} = OptimizationQuery.running_for_deck(optimization.deck_id)
    assert found == optimization.id

    Repo.update!(Ecto.Changeset.change(optimization, status: :done))
    refute OptimizationQuery.running_for_deck(optimization.deck_id)
  end

  describe "the reimagine recipe" do
    test "opens with the visions and closes with two checkpoints" do
      recipe = Deckex.Optimizations.recipe(insert(:deck), :reimagine)

      assert hd(recipe)["lens"] == "visao"
      assert Enum.at(recipe, 1)["kind"] == "reconstruction"
      assert List.last(recipe)["kind"] == "checkpoint"
      assert length(recipe) == 10
    end

    test "it never scouts — a reimagining does not need the old purpose written down" do
      deck = insert(:deck, dossier: nil, dossier_stale: true)

      refute Enum.any?(Deckex.Optimizations.recipe(deck, :reimagine), &(&1["lens"] == "scout"))
    end

    test "refine is unchanged" do
      deck = insert(:deck, dossier: %{"plano" => "x"}, dossier_stale: false)

      assert length(Deckex.Optimizations.recipe(deck, :refine)) == 8
      assert Deckex.Optimizations.recipe(deck) == Deckex.Optimizations.recipe(deck, :refine)
    end
  end

  describe "the mode" do
    test "defaults to refine" do
      assert insert(:optimization).mode == :refine
    end

    test "accepts reimagine" do
      assert insert(:optimization, mode: :reimagine).mode == :reimagine
    end

    test "a run awaiting the owner's choice still blocks a second run" do
      optimization = insert(:optimization, status: :awaiting_choice)

      assert OptimizationQuery.running_for_deck(optimization.deck_id)
    end
  end
end
