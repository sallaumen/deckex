defmodule Deckex.Optimizations.ReimagineTest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Decks.Deck
  alias Deckex.Optimizations
  alias Deckex.Workers.ConsultWorker
  alias Deckex.Workers.OptimizationAdvanceWorker

  setup :verify_on_exit!

  @recipe [
    %{"kind" => "lens", "lens" => "visao", "label" => "Visões"},
    %{"kind" => "reconstruction", "lens" => "full", "label" => "Reconstrução"}
  ]

  @visoes [
    %{
      "nome" => "Mais consistente",
      "eixo" => "consistencia",
      "tese" => "Menos variância.",
      "custo" => "Menos explosão.",
      "cartas_chave" => ["Counterspell"]
    },
    %{
      "nome" => "Mais rápido",
      "eixo" => "velocidade",
      "tese" => "Fecha antes.",
      "custo" => "Fica frágil.",
      "cartas_chave" => ["Sol Ring"]
    },
    %{
      "nome" => "Mais resiliente",
      "eixo" => "resiliencia",
      "tese" => "Aguenta ódio.",
      "custo" => "Fica mais lento.",
      "cartas_chave" => ["Sol Ring"]
    }
  ]

  # Mono-blue so a blue commander swap is legal and Counterspell is in
  # identity — the tests here are about the choice, not about legality.
  defp deck_with_run do
    CatalogueFixture.seed!(~w(sol_ring island counterspell baral_chief_of_compliance))

    stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
      {:ok, %{found: [], not_found: names}}
    end)

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Island", %{name: "Sintético", source: :paste})

    deck = deck |> Deck.changeset(%{color_identity: ["U"]}) |> Repo.update!()

    {:ok, optimization} = Optimizations.start(deck, %{"mode" => :reimagine}, @recipe)

    {deck, optimization}
  end

  defp answer_visions(optimization, visoes) do
    expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"visoes" => visoes}} end)

    {:ok, fetched} = Optimizations.fetch(optimization.id)
    step = Enum.find(fetched.steps, &(&1.status == :running))

    :ok = perform_job(ConsultWorker, %{consult_id: step.consult_id})
    :ok = perform_job(OptimizationAdvanceWorker, %{consult_id: step.consult_id})

    Optimizations.fetch(optimization.id)
  end

  test "the run waits for the owner instead of advancing" do
    {_deck, optimization} = deck_with_run()
    {:ok, waiting} = answer_visions(optimization, @visoes)

    assert waiting.status == :awaiting_choice
    assert Enum.at(waiting.steps, 1).status == :pending
    assert length(Optimizations.vision_consults(waiting)) == 1
  end

  test "resuming without a choice is refused with a reason" do
    {_deck, optimization} = deck_with_run()
    {:ok, waiting} = answer_visions(optimization, @visoes)

    assert {:error, error} = Optimizations.resume(waiting)
    assert error.message =~ "escolha uma direção"
  end

  test "choosing a direction freezes it and runs the next stage" do
    {_deck, optimization} = deck_with_run()
    {:ok, waiting} = answer_visions(optimization, @visoes)

    # Choosing enqueues the next stage; the model is only called when the
    # worker runs, which is why no answer is scripted here.
    {:ok, running} = Optimizations.choose_vision(waiting, 1)

    assert running.status == :running
    assert Optimizations.chosen_vision(running)["nome"] == "Mais rápido"
    assert Enum.at(running.steps, 1).status == :running
  end

  test "a direction that does not exist is refused rather than guessed" do
    {_deck, optimization} = deck_with_run()
    {:ok, waiting} = answer_visions(optimization, @visoes)

    assert {:error, error} = Optimizations.choose_vision(waiting, 9)
    assert error.message =~ "Não achei essa direção"
  end

  test "a chosen direction's legal commander becomes the sandbox's commander" do
    {_deck, optimization} = deck_with_run()

    visoes =
      List.update_at(@visoes, 0, &Map.put(&1, "comandante", "Baral, Chief of Compliance"))

    {:ok, waiting} = answer_visions(optimization, visoes)

    # Before the choice, the sandbox still has the deck's own commanders.
    assert Optimizations.current_commanders(waiting) == waiting.commanders

    {:ok, chosen} = Optimizations.choose_vision(waiting, 0)

    assert Optimizations.current_commanders(chosen) == ["Baral, Chief of Compliance"]
    # The frozen original is untouched — the diff is measured against it.
    assert chosen.commanders != Optimizations.current_commanders(chosen)
  end

  test "a commander the engine refused never reaches the sandbox" do
    {_deck, optimization} = deck_with_run()

    # Sol Ring is not a legendary creature; the vision is still choosable.
    visoes = List.update_at(@visoes, 0, &Map.put(&1, "comandante", "Sol Ring"))
    {:ok, waiting} = answer_visions(optimization, visoes)

    {:ok, chosen} = Optimizations.choose_vision(waiting, 0)

    assert Optimizations.current_commanders(chosen) == chosen.commanders
  end

  test "asking again spends another consult and keeps the declined set" do
    {_deck, optimization} = deck_with_run()
    {:ok, waiting} = answer_visions(optimization, @visoes)

    {:ok, asked} = Optimizations.ask_again(waiting)
    assert asked.status == :running

    {:ok, waiting_again} = answer_visions(asked, @visoes)

    assert waiting_again.status == :awaiting_choice
    # Both sets are on the record, and no position moved.
    assert length(Optimizations.vision_consults(waiting_again)) == 2
    assert length(waiting_again.steps) == 2
  end
end
