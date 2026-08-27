defmodule Deckex.Optimizations.BancadaTest do
  @moduledoc """
  A whole `:curadoria` run, end to end, on a synthetic 100-card deck.

  The mode's premise is that the owner has the last word, and this is where
  that is proved rather than asserted: the cardápio parks instead of applying,
  his choices go through the same audit a model's answer gets, and the critic
  comes back to him instead of correcting him.
  """
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Consults.Vacancy
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Optimizations
  alias Deckex.Workers.ConsultWorker
  alias Deckex.Workers.OptimizationAdvanceWorker

  setup :verify_on_exit!

  @contract %{"mode" => :curadoria, "vagas_corte" => 2, "vagas_entrada" => 3}

  defp deck_with_run(contract \\ @contract) do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate llanowar_elves rhystic_study))

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n98 Forest\n1 Llanowar Elves", %{
        name: "Deck Sintético",
        source: :paste
      })

    deck = deck |> Deck.changeset(%{color_identity: ["G", "U"]}) |> Repo.update!()

    {:ok, optimization} = Optimizations.start(deck, contract)

    {deck, optimization}
  end

  defp answer(optimization_id, response) do
    expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts -> {:ok, response} end)

    {:ok, optimization} = Optimizations.fetch(optimization_id)
    step = Enum.find(optimization.steps, &(&1.status == :running))

    :ok = perform_job(ConsultWorker, %{consult_id: step.consult_id})
    :ok = perform_job(OptimizationAdvanceWorker, %{consult_id: step.consult_id})

    Optimizations.fetch(optimization_id)
  end

  defp plan do
    %{
      "leitura" => "Leitura sintética.",
      "problemas" => [],
      "nao_mexer" => "Nada.",
      "plano" => "Plano.",
      "sinergias" => "Sinergias.",
      "linhas_de_vitoria" => "Vitória.",
      "fraquezas" => "Fraquezas."
    }
  end

  defp vacancy(grupo, vaga, cards) do
    %{
      "grupo" => grupo,
      "vaga" => vaga,
      "candidatos" => Enum.map(cards, &%{"carta" => &1, "porque" => "porque #{&1}"})
    }
  end

  defp cardapio do
    %{
      "leitura" => "Leitura sintética.",
      "cortes" => [
        vacancy("Terreno demais", "Noventa e oito florestas é terreno demais.", ["Forest"]),
        vacancy("Ramp fraco", "Llanowar morre a qualquer varrida.", ["Llanowar Elves"]),
        vacancy("Reserva", "Vaga de reserva.", ["Forest"])
      ],
      "adicoes" => [
        vacancy("Ramp", "Sua curva quer aceleração de 3.", ["Cultivate", "Sol Ring"]),
        vacancy("Card draw", "O deck não compra carta nenhuma.", ["Rhystic Study"])
      ]
    }
  end

  defp gate(optimization) do
    step = Optimizations.open_gate(optimization)

    {step, Optimizations.vacancies(optimization, step)}
  end

  defp pick(step, vacancies, key, name) do
    vacancy = Enum.find(vacancies, &(&1.key == key))
    {:ok, step} = Optimizations.select(step, vacancy, name)

    step
  end

  describe "the recipe" do
    test "is plan, menu, critic — three consults, like a refine round" do
      {deck, _optimization} = deck_with_run()

      assert Enum.map(Optimizations.recipe(deck, :curadoria), & &1["kind"]) ==
               ["plano", "cardapio", "critico"]
    end
  end

  describe "the cardápio gate" do
    test "parks the run instead of applying anything" do
      {_deck, optimization} = deck_with_run()
      {:ok, _planned} = answer(optimization.id, plan())
      {:ok, waiting} = answer(optimization.id, cardapio())

      assert waiting.status == :awaiting_choice

      {step, _vacancies} = gate(waiting)
      assert step.kind == :cardapio
      assert step.applied == []
      assert step.rejected == []
    end

    test "offers the vacancies, with the reserve flagged by the contract's count" do
      {_deck, optimization} = deck_with_run()
      {:ok, _planned} = answer(optimization.id, plan())
      {:ok, waiting} = answer(optimization.id, cardapio())

      {_step, vacancies} = gate(waiting)

      assert Enum.map(vacancies, & &1.key) == ["cut:0", "cut:1", "cut:2", "add:0", "add:1"]
      assert Enum.map(vacancies, & &1.reserve?) == [false, false, true, false, false]
    end

    test "resolves every candidate against the catalogue" do
      {_deck, optimization} = deck_with_run()
      {:ok, _planned} = answer(optimization.id, plan())
      {:ok, waiting} = answer(optimization.id, cardapio())

      {_step, vacancies} = gate(waiting)

      assert Enum.all?(vacancies, fn vacancy ->
               Enum.all?(vacancy.candidatos, & &1.resolved?)
             end)
    end

    test "refuses to resume while the board is open" do
      {_deck, optimization} = deck_with_run()
      {:ok, _planned} = answer(optimization.id, plan())
      {:ok, waiting} = answer(optimization.id, cardapio())

      assert {:error, error} = Optimizations.resume(waiting)
      assert error.code == :board_open
    end
  end

  describe "selecting" do
    setup do
      {_deck, optimization} = deck_with_run()
      {:ok, _planned} = answer(optimization.id, plan())
      {:ok, waiting} = answer(optimization.id, cardapio())

      {step, vacancies} = gate(waiting)

      %{optimization: waiting, step: step, vacancies: vacancies}
    end

    test "survives being read back from the database", %{step: step, vacancies: vacancies} do
      step = pick(step, vacancies, "add:0", "Cultivate")

      assert step.selections == %{"add:0" => "Cultivate"}

      {:ok, reloaded} = Optimizations.fetch(step.optimization_id)

      assert Enum.find(reloaded.steps, &(&1.id == step.id)).selections == %{
               "add:0" => "Cultivate"
             }
    end

    test "a skip is stored, and is not the same as never having decided", ctx do
      %{step: step, vacancies: vacancies} = ctx
      vacancy = Enum.find(vacancies, &(&1.key == "add:0"))

      {:ok, skipped} = Optimizations.select(step, vacancy, nil)
      assert skipped.selections == %{"add:0" => nil}

      {:ok, cleared} = Optimizations.unselect(skipped, vacancy)
      assert cleared.selections == %{}
    end
  end

  describe "committing" do
    setup do
      {deck, optimization} = deck_with_run()
      {:ok, _planned} = answer(optimization.id, plan())
      {:ok, waiting} = answer(optimization.id, cardapio())

      {step, vacancies} = gate(waiting)

      %{deck: deck, optimization: waiting, step: step, vacancies: vacancies}
    end

    test "is refused with nothing chosen", ctx do
      assert {:error, error} = Optimizations.commit(ctx.optimization, ctx.vacancies)
      assert error.code == :board_not_closable
      assert error.message =~ "ainda não escolheu nada"
    end

    test "is refused off 100, and says by how much", ctx do
      %{step: step, vacancies: vacancies} = ctx
      _step = pick(step, vacancies, "add:0", "Cultivate")

      {:ok, optimization} = Optimizations.fetch(ctx.optimization.id)

      assert {:error, error} = Optimizations.commit(optimization, vacancies)
      assert error.message =~ "101 cartas"
      assert error.message =~ "Corte mais 1"
    end

    test "a balanced board is audited and applied, and the run moves on", ctx do
      %{step: step, vacancies: vacancies} = ctx

      step = pick(step, vacancies, "cut:0", "Forest")
      _step = pick(step, vacancies, "add:0", "Cultivate")

      {:ok, optimization} = Optimizations.fetch(ctx.optimization.id)

      assert {:ok, moved} = Optimizations.commit(optimization, vacancies)

      cardapio_step = Enum.find(moved.steps, &(&1.kind == :cardapio))

      assert [
               %{"action" => "cut", "card" => "Forest"},
               %{"action" => "add", "card" => "Cultivate"}
             ] = cardapio_step.applied

      assert moved.status == :running
      assert Enum.find(moved.steps, &(&1.kind == :critico)).status == :running
    end

    test "the reason he sees later carries the need and the card", ctx do
      %{step: step, vacancies: vacancies} = ctx

      step = pick(step, vacancies, "cut:0", "Forest")
      _step = pick(step, vacancies, "add:0", "Cultivate")

      {:ok, optimization} = Optimizations.fetch(ctx.optimization.id)

      {:ok, moved} = Optimizations.commit(optimization, vacancies)

      assert [%{"reason" => reason} | _rest] =
               Enum.find(moved.steps, &(&1.kind == :cardapio)).applied

      assert reason =~ "Noventa e oito florestas é terreno demais."
      assert reason =~ "porque Forest"
    end

    test "his choice is held to the same audit a model's answer is", ctx do
      %{step: step, vacancies: vacancies} = ctx

      # Rhystic Study is US$ 69.24, far over this ceiling.
      step = pick(step, vacancies, "cut:0", "Forest")
      _step = pick(step, vacancies, "add:1", "Rhystic Study")

      {:ok, optimization} = Optimizations.fetch(ctx.optimization.id)

      optimization =
        optimization
        |> Ecto.Changeset.change(%{
          contract: Map.put(optimization.contract, "ceilings", %{"card" => 100, "land" => 100})
        })
        |> Repo.update!()

      {:ok, optimization} = Optimizations.fetch(optimization.id)

      {:ok, moved} = Optimizations.commit(optimization, vacancies)
      cardapio_step = Enum.find(moved.steps, &(&1.kind == :cardapio))

      assert [%{"action" => "cut", "card" => "Forest"}] = cardapio_step.applied
      assert [%{"card" => "Rhystic Study", "problems" => [problem]}] = cardapio_step.rejected
      assert problem =~ "teto"
    end
  end

  describe "the critic" do
    setup do
      {_deck, optimization} = deck_with_run()
      {:ok, _planned} = answer(optimization.id, plan())
      {:ok, waiting} = answer(optimization.id, cardapio())

      {step, vacancies} = gate(waiting)
      step = pick(step, vacancies, "cut:0", "Forest")
      _step = pick(step, vacancies, "add:0", "Cultivate")

      {:ok, optimization} = Optimizations.fetch(waiting.id)

      %{optimization: optimization, vacancies: vacancies}
    end

    test "comes back to him instead of correcting him", ctx do
      {:ok, moved} = Optimizations.commit(ctx.optimization, ctx.vacancies)

      {:ok, waiting} =
        answer(moved.id, %{
          "veredito" => "Faltou compra.",
          "cuts" => [],
          "adds" => [%{"card" => "Rhystic Study", "reason" => "o deck não compra carta"}]
        })

      assert waiting.status == :awaiting_choice

      {step, vacancies} = gate(waiting)
      assert step.kind == :critico
      assert step.applied == []

      assert [%Vacancy{action: :add, grupo: "Correção do crítico"} = only] = vacancies
      assert [%{name: "Rhystic Study"}] = only.candidatos
    end

    test "a critic that proposes nothing finishes the run without another gate", ctx do
      {:ok, moved} = Optimizations.commit(ctx.optimization, ctx.vacancies)

      {:ok, finished} =
        answer(moved.id, %{"veredito" => "Nada a corrigir.", "cuts" => [], "adds" => []})

      refute finished.status == :awaiting_choice
      assert Optimizations.open_gate(finished) == nil
    end
  end
end
