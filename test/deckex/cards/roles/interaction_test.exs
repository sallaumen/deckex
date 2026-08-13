defmodule Deckex.Cards.Roles.InteractionTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles.Interaction
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp card(fixture) do
    struct!(Card, fixture |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs())
  end

  defp kinds(fixture), do: fixture |> card() |> Interaction.classify() |> Enum.map(& &1.kind)

  describe "counter" do
    test "a counterspell is a counter" do
      assert :counter in kinds("counterspell")
    end

    test "a counterspell is not spot removal — it cannot answer a resolved threat" do
      refute :spot_removal in kinds("counterspell")
    end
  end

  describe "spot_removal" do
    test "exiling a single permanent is spot removal" do
      assert :spot_removal in kinds("resculpt")
    end

    test "damage aimed at one creature is spot removal, not a wipe" do
      # Overwhelming Victory reads "deals 5 damage to target creature. Each
      # creature you control gains trample..." — a naive "each creature" match
      # calls this a board wipe. It is not.
      roles = kinds("overwhelming_victory")

      assert :spot_removal in roles
      refute :board_wipe in roles
    end
  end

  describe "board_wipe" do
    test "damage to every creature is a board wipe" do
      assert :board_wipe in kinds("blasphemous_act")
    end

    test "a board wipe is not also counted as spot removal" do
      refute :spot_removal in kinds("blasphemous_act")
    end
  end

  describe "protection" do
    test "granting hexproof is protection" do
      assert :protection in kinds("swiftfoot_boots")
    end
  end

  describe "no match" do
    test "a ramp spell has no interaction role" do
      assert Interaction.classify(card("cultivate")) == []
      assert Interaction.classify(card("sol_ring")) == []
    end
  end
end
