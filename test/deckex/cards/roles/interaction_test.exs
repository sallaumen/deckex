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

    test "shuffling a permanent into its owner's library is removal" do
      # Chaos Warp is the flexible removal blue and red actually get, and it
      # carried no role at all while the rules only knew destroy and exile.
      assert :spot_removal in kinds("chaos_warp")
    end

    test "bouncing someone's creature is removal" do
      assert :spot_removal in kinds("unsummon")
    end

    test "tucking a creature into the library is removal" do
      # Oust: "Put target creature into its owner's library second from the
      # top" — no top-or-bottom phrasing, still gone.
      assert :spot_removal in kinds("oust")
    end

    test "the edict is removal" do
      assert :spot_removal in kinds("diabolic_edict")
    end
  end

  describe "board_wipe" do
    test "damage to every creature is a board wipe" do
      assert :board_wipe in kinds("blasphemous_act")
    end

    test "a board wipe is not also counted as spot removal" do
      refute :spot_removal in kinds("blasphemous_act")
    end

    test "mass bounce closes a board like destruction does" do
      assert :board_wipe in kinds("perplexing_test")
    end

    test "mass -X/-X is a wipe" do
      assert :board_wipe in kinds("toxic_deluge")
    end
  end

  describe "overload" do
    test "a removal spell that overloads is both modes" do
      # Winds of Abandon: one creature for two mana, every creature you don't
      # control for six. The mass mode lives entirely in the keyword.
      roles = kinds("winds_of_abandon")

      assert :spot_removal in roles
      assert :board_wipe in roles
    end

    test "an overloaded pump is neither" do
      assert kinds("weapon_surge") == []
    end
  end

  describe "the shapes that deny a spell" do
    test "tucking a SPELL is a counter in effect, whatever the verb" do
      # Subtlety puts the creature spell on top or bottom of the library — it
      # never resolves, and the deck that plays her is playing a counterspell.
      roles = kinds("subtlety")

      assert :counter in roles
      refute :spot_removal in roles
    end

    test "bouncing a spell and bouncing a permanent are two different answers" do
      # Hullbreaker Horror does both, one mode each.
      roles = kinds("hullbreaker_horror")

      assert :counter in roles
      assert :spot_removal in roles
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
