defmodule Deckex.Decks.DescriptionTest do
  @moduledoc """
  The owner's own words about what a deck is for.

  Everything the app knew about a deck's intent was either measured from the
  list or written by a model. Neither is the person who built it saying what he
  was going for — and when a stage cuts the card that made the whole thing
  work, that missing sentence is usually the one that would have stopped it.
  """
  use Deckex.DataCase, async: true

  alias Deckex.Analysis
  alias Deckex.AnalysisFixture
  alias Deckex.CatalogueFixture
  alias Deckex.Consults.Briefing
  alias Deckex.Decks

  defp deck do
    CatalogueFixture.seed!(~w(sol_ring forest))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck Descrito", source: :paste})

    deck
  end

  describe "what he writes about his own deck" do
    test "is kept against the deck" do
      {:ok, described} = Decks.put_description(deck(), "deck de comida, o loop é a graça")

      assert described.description == "deck de comida, o loop é a graça"
    end

    # A description nobody wrote should read as absent everywhere, not as a
    # heading with nothing under it.
    test "erasing it removes it rather than storing an empty paragraph" do
      {:ok, described} = Decks.put_description(deck(), "algo")

      {:ok, erased} = Decks.put_description(described, "   ")

      assert erased.description == nil
    end

    # It is his, and it is not the dossier: a consult rewrites the dossier and
    # must never touch this.
    test "a scout writing a dossier leaves it alone" do
      {:ok, described} = Decks.put_description(deck(), "o loop de Food é a graça")

      {:ok, scouted} = Decks.put_dossier(described, %{"plano" => "rampa genérica"})

      assert scouted.description == "o loop de Food é a graça"
    end
  end

  describe "the briefing it reaches" do
    defp briefing_with(description) do
      snapshot = AnalysisFixture.snapshot([])

      Briefing.build(Analysis.report(snapshot), snapshot, :full, description: description)
    end

    test "carries his words, and says intent is his to set" do
      briefing = briefing_with("não quero cEDH, quero o loop de Food funcionando")

      assert briefing =~ "O que o dono diz que este deck é"
      assert briefing =~ "não quero cEDH"
      assert briefing =~ "they are the **intent**"
      assert briefing =~ "cannot contradict him on what he *wants*"
    end

    # It is intent, not measurement — so the list still settles questions of
    # fact, and the prompt has to say which is which or the model will treat a
    # sentence as evidence.
    test "does not let intent outrank the list on facts" do
      assert briefing_with("meu deck é rápido") =~ "the list wins on those"
    end

    test "a deck he has not described carries no such section" do
      refute briefing_with(nil) =~ "O que o dono diz"
      refute briefing_with("") =~ "O que o dono diz"
    end
  end
end
