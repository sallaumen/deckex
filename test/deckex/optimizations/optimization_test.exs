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
end
