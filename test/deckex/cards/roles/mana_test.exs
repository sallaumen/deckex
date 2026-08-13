defmodule Deckex.Cards.Roles.ManaTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles.Mana
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp card(fixture) do
    struct!(Card, fixture |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs())
  end

  defp kinds(fixture), do: fixture |> card() |> Mana.classify() |> Enum.map(& &1.kind)

  describe "ramp" do
    test "a mana rock is ramp" do
      assert :ramp in kinds("sol_ring")
    end

    test "a mana dork is ramp" do
      assert :ramp in kinds("llanowar_elves")
    end

    test "a land-fetching sorcery is ramp and fixing" do
      roles = kinds("natures_lore")

      assert :ramp in roles
      assert :fixing in roles
    end

    test "a land-fetching sorcery is ramp even though produced_mana is empty" do
      # Cultivate is the reason oracle text must be read: produced_mana is [],
      # so a rule that only inspects that field misses one of the most-played
      # ramp spells in the format.
      assert card("cultivate").produced_mana == []
      assert :ramp in kinds("cultivate")
    end

    test "a treasure-maker is ramp, but only at medium confidence" do
      match = "storm_kiln_artist" |> card() |> Mana.classify() |> Enum.find(&(&1.kind == :ramp))

      assert match.confidence == :medium
    end

    test "a fetchland is NOT ramp — it sacrifices itself, it does not accelerate" do
      refute :ramp in kinds("arid_mesa")
    end

    test "a land is never ramp" do
      refute :ramp in kinds("command_tower")
      refute :ramp in kinds("steam_vents")
    end
  end

  describe "ritual" do
    test "an instant that adds mana is a ritual, not ramp" do
      roles = kinds("desperate_ritual")

      assert :ritual in roles
      refute :ramp in roles
    end

    test "a permanent that adds mana is ramp, not a ritual" do
      roles = kinds("sol_ring")

      assert :ramp in roles
      refute :ritual in roles
    end
  end

  describe "cost_reduction" do
    test "a creature that discounts your spells is cost reduction" do
      assert :cost_reduction in kinds("goblin_electromancer")
    end

    test "a spell that discounts ITSELF is not cost reduction" do
      # Blasphemous Act says "This spell costs {1} less to cast for each
      # creature on the battlefield" — that discounts nothing but itself.
      refute :cost_reduction in kinds("blasphemous_act")
    end
  end

  describe "fixing" do
    test "a land producing more than one colour is fixing" do
      assert :fixing in kinds("command_tower")
      assert :fixing in kinds("steam_vents")
    end

    test "a fetchland is fixing" do
      assert :fixing in kinds("arid_mesa")
    end

    test "a mono-coloured mana rock is not fixing" do
      refute :fixing in kinds("sol_ring")
    end
  end

  describe "no match" do
    test "a card with no mana role returns no matches" do
      assert Mana.classify(card("counterspell")) == []
      assert Mana.classify(card("young_pyromancer")) == []
    end
  end

  describe "evidence" do
    test "every match names the signal that produced it" do
      for match <- Mana.classify(card("cultivate")) do
        assert is_binary(match.evidence)
        assert match.evidence != ""
      end
    end
  end
end
