defmodule Deckex.Cards.Roles.MillTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles.Mill
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp card(name) do
    struct!(Card, ScryfallFixture.load!(name) |> ScryfallMapper.to_attrs())
  end

  test "milling an opponent is the mill role" do
    assert [%{kind: :mill}] = Mill.classify(card("brain_freeze"))
  end

  test "milling yourself is not — it is a build-around, not a tactic aimed at anyone" do
    assert [] == Mill.classify(card("stitchers_supplier"))
  end

  test "a card with no mill text matches nothing" do
    assert [] == Mill.classify(card("sol_ring"))
  end
end
