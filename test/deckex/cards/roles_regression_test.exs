defmodule Deckex.Cards.RolesRegressionTest do
  @moduledoc """
  Locks in the rule verdicts that a manual pass over a real Commander deck
  produced. These are the numbers the mana and interaction lenses will be built
  on; if a rule change breaks one, this test says so loudly.

  Every case here is a distinction that was got wrong at least once.
  """
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp kinds(fixture) do
    fixture
    |> ScryfallFixture.load!()
    |> ScryfallMapper.to_attrs()
    |> then(&struct!(Card, &1))
    |> Roles.classify()
    |> Enum.map(& &1.kind)
    |> Enum.sort()
  end

  test "Sol Ring is ramp and nothing else" do
    assert kinds("sol_ring") == [:ramp]
  end

  test "Cultivate is ramp and fixing" do
    assert kinds("cultivate") == [:fixing, :ramp]
  end

  test "Desperate Ritual is a ritual, never ramp" do
    roles = kinds("desperate_ritual")

    assert :ritual in roles
    refute :ramp in roles
  end

  test "Goblin Electromancer is cost reduction, never ramp" do
    roles = kinds("goblin_electromancer")

    assert :cost_reduction in roles
    refute :ramp in roles
  end

  test "Goblin Anarchomancer's conditional discount still counts" do
    assert :cost_reduction in kinds("goblin_anarchomancer")
  end

  test "Arid Mesa is fixing, never ramp" do
    assert kinds("arid_mesa") == [:fixing]
  end

  test "Counterspell is a counter, never spot removal" do
    assert kinds("counterspell") == [:counter]
  end

  test "Overwhelming Victory is spot removal, never a board wipe" do
    roles = kinds("overwhelming_victory")

    assert :spot_removal in roles
    refute :board_wipe in roles
  end

  test "Blasphemous Act is a board wipe and not cost reduction" do
    roles = kinds("blasphemous_act")

    assert :board_wipe in roles
    refute :cost_reduction in roles
  end

  test "Mystical Tutor is a tutor; Nature's Lore is not" do
    assert :tutor in kinds("mystical_tutor")
    refute :tutor in kinds("natures_lore")
  end

  test "Finale of Devastation searches two zones and is still a tutor" do
    assert :tutor in kinds("finale_of_devastation")
  end

  test "Smothering Tithe is ramp by its Treasure, and never draw" do
    roles = kinds("smothering_tithe")

    assert :ramp in roles
    refute :draw in roles
  end
end
