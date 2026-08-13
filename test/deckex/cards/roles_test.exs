defmodule Deckex.Cards.RolesTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp card(fixture) do
    struct!(Card, fixture |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs())
  end

  defp kinds(fixture), do: fixture |> card() |> Roles.classify() |> Enum.map(& &1.kind)

  describe "classify/1" do
    test "combines roles from every rule group" do
      roles = kinds("cultivate")

      assert :ramp in roles
      assert :fixing in roles
    end

    test "returns at most one match per kind" do
      kinds = "cultivate" |> card() |> Roles.classify() |> Enum.map(& &1.kind)

      assert kinds == Enum.uniq(kinds)
    end

    test "keeps the highest confidence when a kind matches twice" do
      # Command Tower is fixing by producing five colours (high). Whatever else
      # fires, the surviving match must not be downgraded.
      match = "command_tower" |> card() |> Roles.classify() |> Enum.find(&(&1.kind == :fixing))

      assert match.confidence == :high
    end

    test "a card the rules cannot place returns no matches" do
      assert Roles.classify(card("young_pyromancer")) == []
    end
  end

  describe "residue?/1" do
    test "a confidently classified card is not residue" do
      refute Roles.residue?(card("sol_ring"))
      refute Roles.residue?(card("counterspell"))
    end

    test "a land that taps for mana is never residue" do
      # Asking a model "what role does Forest play" is a question with no useful
      # answer, and a 100-card deck holds dozens of them. The mana lens reads
      # produced_mana directly; no classification is needed.
      refute Roles.residue?(card("forest"))
      refute Roles.residue?(card("reliquary_tower"))
      refute Roles.residue?(card("command_tower"))
    end

    test "an unmatched card is residue and goes to the AI" do
      # Young Pyromancer makes creature tokens off spells. No rule touches it:
      # it produces no mana, answers nothing, and draws nothing. This is exactly
      # the shape the AI pass exists for.
      assert Roles.residue?(card("young_pyromancer"))
    end

    test "Smothering Tithe is caught by the treasure rule, not sent to the AI" do
      # It is one of the format's most-played ramp cards, and a conditional tax
      # engine no removal or draw regex would find — but "create a Treasure
      # token" is a real signal, so the rules get it for free at medium
      # confidence. Every card the rules catch is a card never paid for.
      refute Roles.residue?(card("smothering_tithe"))

      match = "smothering_tithe" |> card() |> Roles.classify() |> Enum.find(&(&1.kind == :ramp))

      assert match.confidence == :medium
    end

    test "an opponent drawing a card is not you drawing a card" do
      refute :draw in kinds("smothering_tithe")
    end
  end
end
