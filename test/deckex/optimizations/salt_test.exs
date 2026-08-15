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

  test "the vocabulary is the one the salt survey is actually made of" do
    keys = Enum.map(Salt.tactics(), & &1.key)

    for named <- ~w(taxation theft hoser forced_sacrifice free_spell chaos) do
      assert named in keys, "faltou #{named}"
    end
  end

  test "mill is not a salt dial — the survey does not support it" do
    refute "mill" in Enum.map(Salt.tactics(), & &1.key)
    # It stays a role the engine can see.
    assert :mill in RoleMatch.kinds()
  end

  test "the calm-table preset avoids the lockout half and no more" do
    preset = Salt.preset("mesa_tranquila")

    for avoided <- ~w(stax mass_land_denial extra_turn taxation hoser theft forced_sacrifice) do
      assert preset[avoided] == "evitar", "#{avoided} devia estar evitado"
    end

    # Ordinary Magic at most tables; the preset does not decide these.
    for tolerated <- ~w(counter graveyard_hate free_spell chaos) do
      assert preset[tolerated] == "tanto_faz"
    end
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
