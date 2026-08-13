defmodule Deckex.Cards.Roles.ValueTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles.Value
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp card(fixture) do
    struct!(Card, fixture |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs())
  end

  defp kinds(fixture), do: fixture |> card() |> Value.classify() |> Enum.map(& &1.kind)

  describe "draw" do
    test "drawing cards is draw" do
      assert :draw in kinds("rhystic_study")
    end

    test "a looting effect is draw" do
      assert :draw in kinds("faithless_looting")
    end

    test "an OPPONENT drawing a card is not you drawing a card" do
      # Smothering Tithe reads "Whenever an opponent draws a card" — that gives
      # you a Treasure, not a card, and must not count towards card advantage.
      refute :draw in kinds("smothering_tithe")
    end
  end

  describe "tutor" do
    test "searching for a non-land card is a tutor" do
      assert :tutor in kinds("mystical_tutor")
    end

    test "searching for a LAND is ramp, not a tutor" do
      # Cultivate and the fetchlands search the library too. They are handled by
      # the mana rules; counting them as tutors would inflate a deck's apparent
      # consistency.
      refute :tutor in kinds("cultivate")
      refute :tutor in kinds("arid_mesa")
      refute :tutor in kinds("natures_lore")
    end
  end

  describe "stax" do
    test "taxing an opponent's spells is stax" do
      assert :stax in kinds("rhystic_study")
    end
  end

  describe "no match" do
    test "a vanilla mana rock has no value role" do
      assert Value.classify(card("sol_ring")) == []
    end
  end
end
