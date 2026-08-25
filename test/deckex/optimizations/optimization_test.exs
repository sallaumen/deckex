defmodule Deckex.Optimizations.OptimizationTest do
  use Deckex.DataCase, async: true

  alias Deckex.Consults.Consult
  alias Deckex.Optimizations
  alias Deckex.Optimizations.OptimizationQuery

  test "an optimization and its steps round-trip every field" do
    optimization = insert(:optimization)
    step = insert(:optimization_step, optimization: optimization)

    fetched = OptimizationQuery.get(optimization.id)

    assert fetched.status == :running
    assert fetched.contract["ceilings"]["land"] == 200
    assert [%{position: 1, kind: :execucao, lens: "execucao"}] = fetched.steps
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
    test "opens with the visions, rebuilds, and closes with the critic" do
      recipe = Deckex.Optimizations.recipe(insert(:deck), :reimagine)

      assert hd(recipe)["kind"] == "visao"
      assert Enum.at(recipe, 1)["kind"] == "reconstruction"
      assert List.last(recipe)["kind"] == "critico"
      assert length(recipe) == 3
    end

    test "it never scouts — a reimagining does not need the old purpose written down" do
      deck = insert(:deck, dossier: nil, dossier_stale: true)

      refute Enum.any?(Deckex.Optimizations.recipe(deck, :reimagine), &(&1["lens"] == "scout"))
    end

    test "refine is unchanged" do
      deck = insert(:deck, dossier: %{"plano" => "x"}, dossier_stale: false)

      assert length(Deckex.Optimizations.recipe(deck, :refine)) == 3
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

  describe "consolidated_diff/1" do
    defp step_with(applied), do: %{applied: applied}
    defp run_with(steps), do: %Deckex.Optimizations.Optimization{steps: steps}

    defp touch(action, card, reason \\ "t"),
      do: %{"action" => action, "card" => card, "reason" => reason}

    # The bug the owner caught on his own run: the mana stage cut two basic
    # Mountains, the diff showed one, and a run that stayed at exactly 100
    # cards reported thirteen cuts against fourteen adds.
    test "two cuts of the same basic land are two cuts" do
      run =
        run_with([
          step_with([touch("cut", "Mountain", "excedente vermelho")]),
          step_with([touch("cut", "Mountain", "segunda do excedente")])
        ])

      assert [first, second] = Optimizations.consolidated_diff(run)
      assert first["card"] == "Mountain"
      assert second["card"] == "Mountain"
      # Each copy keeps its own stage's argument; the second is not an echo.
      assert Enum.sort([first["reason"], second["reason"]]) ==
               ["excedente vermelho", "segunda do excedente"]
    end

    test "a card added and later cut is not in the diff at all" do
      run =
        run_with([
          step_with([touch("add", "Aetherize")]),
          step_with([touch("cut", "Aetherize")])
        ])

      assert Optimizations.consolidated_diff(run) == []
    end

    test "adds and cuts of different cards both survive, sorted" do
      run = run_with([step_with([touch("cut", "Sol Ring"), touch("add", "Cultivate")])])

      assert [%{"card" => "Cultivate"}, %{"card" => "Sol Ring"}] =
               Optimizations.consolidated_diff(run)
    end

    # Three copies in, one out, is two copies in — the count is what a deck
    # holds, and the owner buys from this list.
    test "the net keeps the count, not merely the direction" do
      run =
        run_with([
          step_with([touch("add", "Forest", "a"), touch("add", "Forest", "b")]),
          step_with([touch("add", "Forest", "c"), touch("cut", "Forest", "d")])
        ])

      assert [one, two] = Optimizations.consolidated_diff(run)
      assert one["action"] == "add" and two["action"] == "add"
    end
  end
end
