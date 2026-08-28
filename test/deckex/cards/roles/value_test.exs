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

      # Alania has the opponent draw so she can copy the spell. Still not you.
      refute :draw in kinds("alania_divergent_storm")
    end

    test "a triggered draw in the middle of a sentence is still draw" do
      # "Whenever you cast or copy an instant or sorcery spell, draw a card"
      # is the format's premier card-advantage shape, and a line-start anchor
      # read it as nothing.
      assert :draw in kinds("archmage_emeritus")
    end

    test "putting a pile into your hand is draw that never says draw" do
      assert :draw in kinds("fact_or_fiction")
    end

    test "impulse draw — exile from your library, permission to play — is draw" do
      assert :draw in kinds("light_up_the_stage")
    end

    test "reminder text does not draw" do
      # Ketria Triome's only "Draw a card" lives inside the cycling reminder.
      # A land that cycles is card selection, not a draw engine.
      refute :draw in kinds("ketria_triome")
    end
  end

  describe "wincon" do
    test "a card that names the win is a wincon" do
      assert :wincon in kinds("felidar_sovereign")
    end

    test "a card that does not name it is not" do
      refute :wincon in kinds("rhystic_study")
    end
  end

  describe "tutor" do
    test "searching for a non-land card is a tutor" do
      assert :tutor in kinds("mystical_tutor")
    end

    test "a search that names another zone is still a tutor" do
      # Finale of Devastation reads "Search your library and/or graveyard for a
      # creature card" — a rule expecting "search your library for" verbatim
      # misses it.
      assert :tutor in kinds("finale_of_devastation")
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

  describe "graveyard hate" do
    test "filing a graveyard into a library is hate, exile or not" do
      # Endurance puts the graveyard on the bottom of its owner's library —
      # no "exile" for the old pattern to see, same graveyard gone.
      assert :graveyard_hate in kinds("endurance")
    end
  end

  describe "no match" do
    test "a vanilla mana rock has no value role" do
      assert Value.classify(card("sol_ring")) == []
    end
  end
end
