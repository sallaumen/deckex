defmodule Deckex.Consults.ModelFloorTest do
  @moduledoc """
  The floor is about what an answer CHANGES, not what it costs.

  Every `sonnet` full-deck answer this project ever ran proposed cuts and adds
  — three of three — while the scout and bracket lenses, which propose nothing
  at all, ran on the expensive model. The floor draws the line in the one place
  that matters.
  """
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.CatalogueFixture
  alias Deckex.Consults
  alias Deckex.Decks
  alias Deckex.Optimizations
  alias Deckex.Settings

  setup :verify_on_exit!

  test "models rank by capability, and an unknown one ranks lowest" do
    assert Consults.model_rank("fable") > Consults.model_rank("opus")
    assert Consults.model_rank("opus") > Consults.model_rank("sonnet")
    assert Consults.model_rank("sonnet") > Consults.model_rank("haiku")
    # A typo must never accidentally clear the floor.
    assert Consults.model_rank("fabel") == 0
    assert Consults.model_rank(nil) == 0
  end

  test "reading lenses are free; every other lens changes the deck" do
    refute Consults.changes_deck?(:scout)
    refute Consults.changes_deck?(:bracket)

    for lens <- [:full, :matchup, :budget, :upgrade, :speed_curve, :consistency, :alinhamento] do
      assert Consults.changes_deck?(lens), "#{lens} muda o deck"
    end
  end

  test "a vision changes the deck even though it proposes no cuts or adds" do
    # It names what the owner will buy and steers nine stages after it.
    assert Consults.changes_deck?(:visao)
  end

  test "the launcher only offers models it will accept" do
    offered = Consults.models_at_or_above("opus")

    assert "fable" in offered
    assert "opus" in offered
    refute "sonnet" in offered
    # Strongest first.
    assert hd(offered) == "fable"
  end

  describe "the pipeline refuses below the floor" do
    setup do
      CatalogueFixture.seed!(~w(sol_ring forest))

      stub(Deckex.Scryfall.Mock, :fetch_by_names, fn names ->
        {:ok, %{found: [], not_found: names}}
      end)

      {:ok, deck} =
        Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck do Piso", source: :paste})

      %{deck: deck}
    end

    test "and says which model and which floor", %{deck: deck} do
      assert {:error, error} = Optimizations.start(deck, %{"model" => "haiku"})

      assert error.message =~ "haiku"
      assert error.message =~ Settings.model_floor()
      assert Optimizations.list_for_deck(deck.id) == []
    end

    test "at the floor it launches", %{deck: deck} do
      recipe = [%{"kind" => "execucao", "lens" => "execucao", "label" => "Mana"}]

      assert {:ok, _run} = Optimizations.start(deck, %{"model" => "fable"}, recipe)
    end
  end
end
