defmodule Deckex.Optimizations.SaltTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.RoleMatch
  alias Deckex.Optimizations.Salt

  test "every tactic names a role the engine actually classifies" do
    kinds = RoleMatch.kinds()

    assert Enum.all?(Salt.tactics(), &(&1.role in kinds))
  end

  test "avoided roles come back keyed by role, carrying the label for the refusal" do
    assert %{counter: "counters"} = Salt.avoided(%{"counter" => "evitar"})
  end

  test "wanted and indifferent tactics are not avoided" do
    assert Salt.avoided(%{"counter" => "quero", "stax" => "tanto_faz"}) == %{}
  end

  test "the calm-table preset avoids the tactics that make people quit" do
    preset = Salt.preset("mesa_tranquila")

    assert preset["stax"] == "evitar"
    assert preset["mass_land_denial"] == "evitar"
    assert preset["extra_turn"] == "evitar"
    assert preset["mill"] == "evitar"
    # Counters are rude to some tables and normal to others; the preset does
    # not decide that for the owner.
    assert preset["counter"] == "tanto_faz"
  end

  test "no-brakes avoids nothing" do
    assert Salt.avoided(Salt.preset("sem_freio")) == %{}
  end

  test "wanting land denial under bracket 3 is a contract that contradicts itself" do
    contract = %{"bracket_max" => 3, "salt" => %{"mass_land_denial" => "quero"}}

    assert Salt.contradiction(contract) =~ "Bracket 4"
  end

  test "the same wish is fine at bracket 4" do
    contract = %{"bracket_max" => 4, "salt" => %{"mass_land_denial" => "quero"}}

    assert Salt.contradiction(contract) == nil
  end

  test "merely tolerating land denial is not a contradiction" do
    contract = %{"bracket_max" => 3, "salt" => %{"mass_land_denial" => "tanto_faz"}}

    assert Salt.contradiction(contract) == nil
  end
end
