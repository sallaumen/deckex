defmodule Deckex.Analysis.InteractionBandTest do
  @moduledoc """
  Interaction is a band, not a floor.

  No published source argues that more interaction is always better, and the
  failure at the top end is documented: a table where nobody can keep a
  permanent is a table where nobody gets to play. A floor-only model could
  never say that.
  """
  use Deckex.DataCase, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Interaction
  alias Deckex.Cards
  alias Deckex.CatalogueFixture
  alias Deckex.Decks

  setup do
    ~w(sol_ring forest counterspell resculpt blasphemous_act overwhelming_victory)
    |> CatalogueFixture.seed!()
    |> Enum.each(&Cards.classify_card/1)

    :ok
  end

  defp snapshot(list) do
    {:ok, deck} = Decks.import_from_text(list, %{name: "Deck da Faixa", source: :paste})

    Decks.snapshot(deck)
  end

  defp codes(snapshot, baselines) do
    snapshot |> Interaction.findings(baselines) |> Enum.map(& &1.code)
  end

  test "past the ceiling it says so" do
    snapshot = snapshot("4 Forest\n1 Counterspell\n1 Resculpt\n1 Blasphemous Act")

    # A ceiling of one puts this deck over it without needing a huge fixture.
    baselines = %{Baselines.default() | interaction_max: 1, interaction_floor: 0}

    assert "interaction.too_much" in codes(snapshot, baselines)
  end

  test "inside the band it says nothing about the total" do
    snapshot = snapshot("4 Forest\n1 Counterspell\n1 Resculpt")

    baselines = %{Baselines.default() | interaction_max: 16, interaction_floor: 0}

    refute "interaction.too_much" in codes(snapshot, baselines)
    refute "interaction.total_low" in codes(snapshot, baselines)
  end

  test "the shipped defaults name their source" do
    assert Baselines.source() =~ "Command Zone"
    # Raised from 8 with the 2025 revision, whose reason was a faster format.
    assert Baselines.default().interaction_target == 10
    assert Baselines.default().draw_target == 10
  end
end
