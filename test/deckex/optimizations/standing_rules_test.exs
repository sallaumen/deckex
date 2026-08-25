defmodule Deckex.Optimizations.StandingRulesTest do
  @moduledoc """
  What the owner decided on the Cartas screen, reaching a running pipeline.

  The launch modal used to be the only place to protect a card, and it came up
  empty every time — so protecting a combo piece meant remembering it under
  pressure, which is exactly how one got cut. These tests are the promise that
  he only has to say it once.
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
    %{"kind" => "execucao", "lens" => "execucao", "label" => "Mana"},
    %{"kind" => "execucao", "lens" => "execucao", "label" => "Early game"}
  ]

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate rhystic_study))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n99 Forest", %{name: "Deck das Ordens", source: :paste})

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

  describe "a card he locked once" do
    test "is already in the contract of a run launched with an empty form" do
      deck = deck()
      {:ok, _rule} = Decks.put_card_rules(deck, "Sol Ring | é o motor", :locked)

      assert Optimizations.default_contract(deck)["keep"] == ["Sol Ring"]
    end

    # The failure this exists to prevent: the launch form posts `keep => []`
    # because he did not retype anything, `Map.merge/2` takes the empty list,
    # and the lock silently evaporates for that run.
    test "survives a launch form that posts nothing" do
      deck = deck()
      {:ok, _rule} = Decks.put_card_rules(deck, "Sol Ring", :locked)

      {:ok, optimization} = Optimizations.start(deck, %{"keep" => []}, @two_lenses)

      assert optimization.contract["keep"] == ["Sol Ring"]
    end

    test "makes the engine refuse the cut, without him saying it twice" do
      stub_scryfall()
      deck = deck()
      {:ok, _rule} = Decks.put_card_rules(deck, "Sol Ring | é o motor", :locked)

      {:ok, optimization} = Optimizations.start(deck, %{}, @two_lenses)

      expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer(["Sol Ring"], []) end)
      {:ok, after_first} = beat(optimization.id)

      [first | _rest] = after_first.steps
      assert [%{"card" => "Sol Ring", "problems" => [problem]}] = first.rejected
      assert problem =~ "lista de proteção"
      assert first.applied == []
    end

    # He watches his rounds, and the reason he watches is to catch this. A lock
    # written at stage one has to bind stage two — telling him "next round"
    # about a card being cut in front of him would be useless.
    test "binds the stage after the one where he wrote it" do
      stub_scryfall()
      deck = deck()

      {:ok, optimization} = Optimizations.start(deck, %{}, @two_lenses)

      expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer([], ["Cultivate"]) end)
      {:ok, _after_first} = beat(optimization.id)

      {:ok, _rule} = Decks.put_card_rules(deck, "Cultivate | acabei de ver, fica", :locked)

      expect(Deckex.AI.Mock, :complete, fn _p, _s, _o -> answer(["Cultivate"], []) end)
      {:ok, final} = beat(optimization.id)

      [_first, second | _rest] = final.steps
      assert [%{"card" => "Cultivate", "problems" => [problem]}] = second.rejected
      assert problem =~ "lista de proteção"
    end

    test "reaches the briefing as an order, with the reason he gave" do
      stub_scryfall()
      deck = deck()

      {:ok, _rule} =
        Decks.put_card_rules(deck, "Sol Ring | metade do combo, não pode sair", :locked)

      {:ok, optimization} = Optimizations.start(deck, %{}, @two_lenses)
      [step | _rest] = optimization.steps
      {:ok, consult} = Deckex.Consults.fetch(step.consult_id)

      assert consult.briefing =~ "Cartas que o dono trancou neste deck"
      assert consult.briefing =~ "metade do combo, não pode sair"
      assert consult.briefing =~ "Protected cards (never cut): Sol Ring"
    end
  end

  describe "a round of one stage" do
    test "is one stage, and it is his" do
      deck = deck()

      assert [%{"lens" => "livre", "label" => "Ajuste direto"}] =
               Optimizations.recipe(deck, :livre)
    end

    test "carries his request into the briefing verbatim" do
      stub_scryfall()
      deck = deck()

      {:ok, optimization} =
        Optimizations.start(deck, %{
          "mode" => :livre,
          "pedido" => "tira duas terras e põe rampa de duas"
        })

      assert optimization.mode == :livre
      assert [step] = optimization.steps

      {:ok, consult} = Deckex.Consults.fetch(step.consult_id)
      assert consult.briefing =~ "tira duas terras e põe rampa de duas"
      assert consult.briefing =~ "single-stage round"
    end

    # Launching one with nothing written is not a mistake — it means "do what I
    # already told you", and everything he told it is in the briefing already.
    test "with no request at all is a round about his standing decisions" do
      stub_scryfall()
      deck = deck()
      {:ok, _rule} = Decks.put_card_rules(deck, "Cultivate | quero essa", :wanted)

      {:ok, optimization} = Optimizations.start(deck, %{"mode" => :livre, "pedido" => ""})

      [step] = optimization.steps
      {:ok, consult} = Deckex.Consults.fetch(step.consult_id)

      assert consult.briefing =~ "without writing a request"
      assert consult.briefing =~ "Cartas que o dono está pedindo"
      assert consult.briefing =~ "Cultivate"
    end
  end
end
