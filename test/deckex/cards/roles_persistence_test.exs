defmodule Deckex.Cards.RolesPersistenceTest do
  use Deckex.DataCase, async: true

  alias Deckex.Cards
  alias Deckex.CatalogueFixture

  # One ordered, conflict-safe batch per test — see `Deckex.CatalogueFixture`
  # for why the order is load-bearing and why it must be a single call.
  defp seed(names) do
    CatalogueFixture.seed_map!(names)
  end

  describe "classify_card/1" do
    test "persists the roles the rules found, stamped as :rule" do
      %{"sol_ring" => card} = seed(~w(sol_ring))

      assert {:ok, roles} = Cards.classify_card(card)
      assert [%{kind: :ramp, source: :rule, confidence: :high}] = roles
      assert hd(roles).evidence =~ "produz"
    end

    test "persists several roles for one card" do
      %{"cultivate" => card} = seed(~w(cultivate))

      assert {:ok, roles} = Cards.classify_card(card)
      assert Enum.sort(Enum.map(roles, & &1.kind)) == [:fixing, :ramp]
    end

    test "is idempotent — re-classifying does not duplicate rows" do
      %{"cultivate" => card} = seed(~w(cultivate))

      assert {:ok, _first} = Cards.classify_card(card)
      assert {:ok, _second} = Cards.classify_card(card)

      assert length(Cards.roles_for(card)) == 2
    end

    test "stores nothing for a card the rules cannot place" do
      %{"young_pyromancer" => card} = seed(~w(young_pyromancer))

      assert {:ok, []} = Cards.classify_card(card)
      assert Cards.roles_for(card) == []
    end
  end

  describe "set_role_manually/3" do
    test "records a manual role" do
      %{"young_pyromancer" => card} = seed(~w(young_pyromancer))

      assert {:ok, role} = Cards.set_role_manually(card, :wincon, "eu decidi")
      assert %{kind: :wincon, source: :manual, confidence: :high} = role
    end

    test "a manual role is never overwritten by a later rule pass" do
      %{"sol_ring" => card} = seed(~w(sol_ring))

      # The rules say Sol Ring is :ramp at high confidence. A human overrides
      # that verdict for their own reasons, and the override must survive.
      assert {:ok, _manual} = Cards.set_role_manually(card, :ramp, "não conta como ramp aqui")
      assert {:ok, _rules} = Cards.classify_card(card)

      assert [%{kind: :ramp, source: :manual, evidence: "não conta como ramp aqui"}] =
               Cards.roles_for(card)
    end

    test "a manual role coexists with rule roles on the same card" do
      %{"cultivate" => card} = seed(~w(cultivate))

      assert {:ok, _rules} = Cards.classify_card(card)
      assert {:ok, _manual} = Cards.set_role_manually(card, :wincon, "fecha o jogo comigo")

      roles = Cards.roles_for(card)

      assert Enum.sort(Enum.map(roles, & &1.kind)) == [:fixing, :ramp, :wincon]
      assert Enum.find(roles, &(&1.kind == :wincon)).source == :manual
      assert Enum.find(roles, &(&1.kind == :ramp)).source == :rule
    end
  end

  describe "roles_for/1" do
    test "returns an empty list for an unclassified card" do
      %{"sol_ring" => sol_ring} = seed(~w(sol_ring))

      assert Cards.roles_for(sol_ring) == []
    end
  end
end
