defmodule Deckex.Optimizations.ApplyToDeckTest do
  use Deckex.DataCase, async: true

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Decks.DeckVersion
  alias Deckex.Decks.Versions
  alias Deckex.Optimizations
  alias Deckex.Optimizations.OptimizationStep

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest natures_lore cultivate counterspell rhystic_study))

    {:ok, deck} =
      Decks.import_from_text("Commander:\n1 Nature's Lore\n\nDeck:\n1 Sol Ring\n4 Forest", %{
        name: "Deck Aplicado",
        source: :paste
      })

    deck
  end

  # A run whose one stage cut Sol Ring and added Cultivate, done the way the
  # pipeline does it: the changelog and the resulting list, both stored.
  defp run_over(deck, opts \\ []) do
    {:ok, run} =
      Optimizations.start(deck, %{}, [%{"kind" => "lens", "lens" => "full", "label" => "Tudo"}])

    [step] = run.steps

    applied =
      Keyword.get(opts, :applied, [
        %{"action" => "cut", "card" => "Sol Ring", "reason" => "lento"},
        %{"action" => "add", "card" => "Cultivate", "reason" => "rampa"}
      ])

    {:ok, _step} =
      step
      |> OptimizationStep.changeset(%{
        status: :done,
        applied: applied,
        list_after: Optimizations.apply_changes_to_list(step.list_before, applied)
      })
      |> Repo.update()

    {:ok, run} = Optimizations.fetch(run.id)

    run
  end

  describe "apply_to_deck/2" do
    test "the deck itself gets the list — no second deck appears" do
      deck = deck()
      run = run_over(deck)

      {:ok, applied} = Optimizations.apply_to_deck(run)

      assert applied.id == deck.id
      assert Repo.aggregate(Deckex.Decks.Deck, :count) == 1

      names = applied |> Decks.list_deck_cards() |> Enum.map(& &1.card.name) |> Enum.sort()
      assert names == ["Cultivate", "Forest", "Nature's Lore"]
    end

    test "the commander stays the commander" do
      deck = deck()
      run = run_over(deck)

      {:ok, applied} = Optimizations.apply_to_deck(run)

      assert [%{card: %{name: "Nature's Lore"}}] =
               applied |> Decks.list_deck_cards() |> Enum.filter(&(&1.board == :commander))
    end

    test "quantities survive" do
      deck = deck()
      run = run_over(deck)

      {:ok, applied} = Optimizations.apply_to_deck(run)

      forest = applied |> Decks.list_deck_cards() |> Enum.find(&(&1.card.name == "Forest"))
      assert forest.quantity == 4
    end

    test "the run becomes a version that says what it did" do
      deck = deck()
      run = run_over(deck)

      {:ok, applied} = Optimizations.apply_to_deck(run)

      [latest | _older] = Versions.list(applied)

      assert latest.origin == :optimization
      assert latest.optimization_id == run.id
      assert latest.label =~ "Otimização"

      assert Enum.map(DeckVersion.applied(latest), &{&1["action"], &1["card"]}) == [
               {"add", "Cultivate"},
               {"cut", "Sol Ring"}
             ]
    end

    # A card added by one stage and cut by a later one nets to nothing. The
    # history is what happened to the deck, not a transcript of the run.
    test "the changelog is the net, not every touch" do
      deck = deck()

      run =
        run_over(deck,
          applied: [
            %{"action" => "add", "card" => "Cultivate", "reason" => "rampa"},
            %{"action" => "cut", "card" => "Cultivate", "reason" => "pensando melhor"}
          ]
        )

      {:ok, applied} = Optimizations.apply_to_deck(run)

      [latest | _older] = Versions.list(applied)
      assert DeckVersion.applied(latest) == []
    end

    # Overwriting a list nobody had saved would destroy it.
    test "a hand edit made before applying is kept as its own version" do
      deck = deck()
      {:ok, _} = Decks.add_card(deck, "Counterspell")
      run = run_over(deck)

      {:ok, applied} = Optimizations.apply_to_deck(run)

      labels = applied |> Versions.list() |> Enum.map(& &1.label)
      assert "Antes de aplicar" in labels

      {:ok, kept} = Versions.fetch(applied, 2)
      assert Enum.any?(DeckVersion.rows(kept), &(&1["name"] == "Counterspell"))
    end

    test "applying twice in a row does not invent a version for nothing" do
      deck = deck()
      run = run_over(deck)

      {:ok, applied} = Optimizations.apply_to_deck(run)
      before = length(Versions.list(applied))

      {:ok, applied} = Optimizations.apply_to_deck(run)

      # One new version for the second apply, and no "Antes de aplicar" in
      # between: nothing had drifted.
      assert length(Versions.list(applied)) == before + 1
    end

    test "from one stage, the list is that stage's" do
      deck = deck()
      run = run_over(deck)
      [step] = run.steps

      {:ok, applied} = Optimizations.apply_to_deck(run, step)

      [latest | _older] = Versions.list(applied)
      assert latest.label =~ "etapa #{step.position}"
    end

    # The catalogue is the only thing that can make this impossible, and a deck
    # half applied is worse than one not applied.
    test "a card the catalogue does not know refuses the whole apply" do
      deck = deck()

      run =
        run_over(deck,
          applied: [%{"action" => "add", "card" => "Carta Que Não Existe", "reason" => "?"}]
        )

      assert {:error, %Deckex.Error{code: :cards_not_found}} = Optimizations.apply_to_deck(run)

      names = deck |> Decks.list_deck_cards() |> Enum.map(& &1.card.name) |> Enum.sort()
      assert names == ["Forest", "Nature's Lore", "Sol Ring"]
    end
  end
end
