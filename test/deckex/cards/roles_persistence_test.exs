defmodule Deckex.Cards.RolesPersistenceTest do
  use Deckex.DataCase, async: true

  alias Deckex.Cards
  alias Deckex.Cards.Card
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.ScryfallFixture

  defp insert_fixture(name) do
    attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

    %Card{} |> Card.changeset(attrs) |> Repo.insert!()
  end

  describe "classify_card/1" do
    test "persists the roles the rules found, stamped as :rule" do
      card = insert_fixture("sol_ring")

      assert {:ok, roles} = Cards.classify_card(card)
      assert [%{kind: :ramp, source: :rule, confidence: :high}] = roles
      assert hd(roles).evidence =~ "produz"
    end

    test "persists several roles for one card" do
      card = insert_fixture("cultivate")

      assert {:ok, roles} = Cards.classify_card(card)
      assert Enum.sort(Enum.map(roles, & &1.kind)) == [:fixing, :ramp]
    end

    test "is idempotent — re-classifying does not duplicate rows" do
      card = insert_fixture("cultivate")

      assert {:ok, _first} = Cards.classify_card(card)
      assert {:ok, _second} = Cards.classify_card(card)

      assert length(Cards.roles_for(card)) == 2
    end

    test "stores nothing for a card the rules cannot place" do
      card = insert_fixture("young_pyromancer")

      assert {:ok, []} = Cards.classify_card(card)
      assert Cards.roles_for(card) == []
    end
  end

  describe "set_role_manually/3" do
    test "records a manual role" do
      card = insert_fixture("young_pyromancer")

      assert {:ok, role} = Cards.set_role_manually(card, :wincon, "eu decidi")
      assert %{kind: :wincon, source: :manual, confidence: :high} = role
    end

    test "a manual role is never overwritten by a later rule pass" do
      card = insert_fixture("sol_ring")

      # The rules say Sol Ring is :ramp at high confidence. A human overrides
      # that verdict for their own reasons, and the override must survive.
      assert {:ok, _manual} = Cards.set_role_manually(card, :ramp, "não conta como ramp aqui")
      assert {:ok, _rules} = Cards.classify_card(card)

      assert [%{kind: :ramp, source: :manual, evidence: "não conta como ramp aqui"}] =
               Cards.roles_for(card)
    end

    test "a manual role coexists with rule roles on the same card" do
      card = insert_fixture("cultivate")

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
      assert Cards.roles_for(insert_fixture("sol_ring")) == []
    end
  end
end
