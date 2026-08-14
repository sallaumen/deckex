defmodule Deckex.Cards.Roles.BracketTest do
  @moduledoc """
  Both roles here push a deck to bracket 4 on their own, so a false positive
  does not merely mislabel a card — it relabels the deck. The negative cases
  matter as much as the positive ones and outnumber them on purpose.
  """
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles.Bracket

  defp kinds(text) do
    %Card{oracle_text: text, type_line: "Sorcery"} |> Bracket.classify() |> Enum.map(& &1.kind)
  end

  describe "mass land denial" do
    test "destroying every land is denial" do
      assert :mass_land_denial in kinds("Destroy all lands.")
    end

    test "a land buried in a list of types is still denial" do
      # Jokulhaups. The first draft of this rule stopped at the comma and
      # missed it, which is why the list case is pinned here.
      assert :mass_land_denial in kinds("Destroy all artifacts, creatures, and lands.")
    end

    test "nonbasic-only denial counts" do
      assert :mass_land_denial in kinds("Destroy all nonbasic lands.")
    end

    test "everyone sacrificing a land counts" do
      assert :mass_land_denial in kinds("Each player sacrifices a land.")
    end

    test "destroying ONE land is not mass denial" do
      refute :mass_land_denial in kinds("Sacrifice this: Destroy target land.")
    end

    test "a creature wipe is not land denial" do
      refute :mass_land_denial in kinds("Destroy all creatures. They can't be regenerated.")
    end

    test "keeping lands tapped is stax, not denial" do
      refute :mass_land_denial in kinds("Players can't untap more than one land.")
    end

    test "searching for a land is certainly not denial" do
      refute :mass_land_denial in kinds("Search your library for a Forest card.")
    end
  end

  describe "extra turns" do
    test "the printed effect is reported" do
      assert :extra_turn in kinds("Take an extra turn after this one.")
    end

    test "granting one to a player counts too" do
      assert :extra_turn in kinds("Target player takes an extra turn after this one.")
    end

    test "an extra combat phase is not an extra turn" do
      refute :extra_turn in kinds(
               "Untap all creatures you control. After this phase, there is an additional combat phase."
             )
    end

    test "skipping a turn is not taking one" do
      refute :extra_turn in kinds("You skip your next turn.")
    end
  end
end
