defmodule Deckex.Cards.Roles.TableTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.Roles.Table
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp kinds(name) do
    name
    |> ScryfallFixture.load!()
    |> ScryfallMapper.to_attrs()
    |> then(&struct!(Card, &1))
    |> Table.classify()
    |> Enum.map(& &1.kind)
  end

  describe "taxation — the pay-or-I-profit pattern" do
    test "catches the 'unless that player pays' shape" do
      assert :taxation in kinds("rhystic_study")
    end

    test "catches the 'may pay, and if they don't' shape" do
      assert :taxation in kinds("smothering_tithe")
    end
  end

  test "theft needs an opponent's card changing hands" do
    assert :theft in kinds("tergrid")
  end

  test "a hoser removes a category of play, not a resource" do
    assert :hoser in kinds("drannith_magistrate")
    # Humility does not say "can't"; it takes every ability away, which is the
    # same crime by another wording.
    assert :hoser in kinds("humility")
  end

  test "forced sacrifice is an edict" do
    assert :forced_sacrifice in kinds("grave_pact")
  end

  test "a free spell has a non-mana alternative cost" do
    assert :free_spell in kinds("force_of_will")
  end

  test "chaos is explicit randomness" do
    assert :chaos in kinds("krarks_thumb")
  end

  describe "the near-misses, which are the point" do
    test "a mana rock is none of these" do
      assert kinds("sol_ring") == []
    end

    test "an ordinary counterspell is not a free spell" do
      refute :free_spell in kinds("counterspell")
    end

    test "destroying everything is not forcing a sacrifice" do
      refute :forced_sacrifice in kinds("blasphemous_act")
    end

    test "putting your own lands onto the battlefield is not theft" do
      refute :theft in kinds("cultivate")
    end

    # These three came out of the real catalogue: each matched on the printed
    # phrase and each was wrong for a different reason.
    test "a soft counter is not ongoing taxation" do
      refute :taxation in kinds("flusterstorm")
    end

    test "cascade hands you other cards; it is not a free spell" do
      refute :free_spell in kinds("apex_devastator")
    end

    test "turning off one permanent's abilities for a turn is not a hoser" do
      refute :hoser in kinds("koma")
    end
  end
end
