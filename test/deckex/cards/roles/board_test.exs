defmodule Deckex.Cards.Roles.BoardTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles.Board
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp card(fixture) do
    struct!(Card, fixture |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs())
  end

  defp kinds(fixture), do: fixture |> card() |> Board.classify() |> Enum.map(& &1.kind)

  describe "token_engine" do
    test "a permanent that makes a creature per trigger is an engine" do
      # Young Pyromancer: "Whenever you cast an instant or sorcery spell,
      # create a 1/1 red Elemental creature token." — the spine of a go-wide
      # spellslinger deck, and worth more than most creatures.
      assert :token_engine in kinds("young_pyromancer")
      assert :token_engine in kinds("talrand_sky_summoner")
    end

    test "a one-shot token spell is a burst, not an engine" do
      # Spectral Procession made three bodies once. It does not defend next
      # turn, and it is the AI's judgement call, not a rule's.
      refute :token_engine in kinds("spectral_procession")

      # Arachnogenesis makes blockers at instant speed — once.
      refute :token_engine in kinds("arachnogenesis")
    end

    test "a treasure maker is ramp, never a token engine" do
      # Smothering Tithe creates a token per opponent draw — a Treasure, which
      # is mana, not a body.
      refute :token_engine in kinds("smothering_tithe")
    end
  end

  describe "anthem" do
    test "a static pump on a permanent is an anthem" do
      assert :anthem in kinds("glorious_anthem")
    end

    test "granting the team an ability is an anthem" do
      # Bria: "Other creatures you control have prowess." — the payoff half of
      # the go-wide plan.
      assert :anthem in kinds("bria_riptide_rogue")
    end

    test "a card that lifts only itself is not an anthem" do
      refute :anthem in kinds("young_pyromancer")
    end
  end
end
