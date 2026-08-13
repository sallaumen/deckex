defmodule Deckex.Cards.RoleAITest do
  use Deckex.DataCase, async: true

  import Mox

  alias Deckex.Cards
  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleAI
  alias Deckex.Cards.ScryfallMapper
  alias Deckex.Error
  alias Deckex.ScryfallFixture

  setup :verify_on_exit!

  defp insert_fixture(name) do
    attrs = name |> ScryfallFixture.load!() |> ScryfallMapper.to_attrs()

    %Card{} |> Card.changeset(attrs) |> Repo.insert!()
  end

  describe "schema/0" do
    test "constrains roles to the known vocabulary" do
      enum =
        get_in(RoleAI.schema(), [
          "properties",
          "cards",
          "items",
          "properties",
          "roles",
          "items",
          "enum"
        ])

      assert "ramp" in enum
      assert "cost_reduction" in enum
      refute "banana" in enum
    end
  end

  describe "classify/1" do
    test "asks the model only about the cards it is given" do
      card = insert_fixture("young_pyromancer")

      expect(Deckex.AI.Mock, :complete, fn prompt, _schema, _opts ->
        assert prompt =~ "Young Pyromancer"

        {:ok,
         %{
           "cards" => [
             %{"name" => "Young Pyromancer", "roles" => ["wincon"], "reasoning" => "faz fichas"}
           ]
         }}
      end)

      assert {:ok, matches} = RoleAI.classify([card])
      assert [%{kind: :wincon, confidence: :medium, evidence: "faz fichas"}] = matches[card.id]
    end

    test "ignores a role the model invented" do
      card = insert_fixture("young_pyromancer")

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:ok,
         %{
           "cards" => [
             %{"name" => "Young Pyromancer", "roles" => ["wincon", "banana"], "reasoning" => "x"}
           ]
         }}
      end)

      assert {:ok, matches} = RoleAI.classify([card])
      assert Enum.map(matches[card.id], & &1.kind) == [:wincon]
    end

    test "ignores a card name the model hallucinated" do
      card = insert_fixture("young_pyromancer")

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:ok,
         %{
           "cards" => [
             %{"name" => "Carta Que Não Existe", "roles" => ["ramp"], "reasoning" => "x"}
           ]
         }}
      end)

      assert {:ok, matches} = RoleAI.classify([card])
      assert matches == %{}
    end

    test "returns an empty map without calling the model for an empty list" do
      assert {:ok, matches} = RoleAI.classify([])
      # `%{}` on the left of a match would succeed against ANY map, so compare.
      assert matches == %{}
    end

    test "propagates an AI failure as a domain error" do
      card = insert_fixture("young_pyromancer")

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:error, Error.new(:ai_timeout, "estourou")}
      end)

      assert {:error, %Error{code: :ai_timeout}} = RoleAI.classify([card])
    end
  end

  describe "Cards.classify_all/1" do
    test "uses rules for what it can and the AI only for the residue" do
      sol_ring = insert_fixture("sol_ring")
      pyromancer = insert_fixture("young_pyromancer")

      # Sol Ring never reaches the model: the rules place it for free.
      expect(Deckex.AI.Mock, :complete, fn prompt, _schema, _opts ->
        assert prompt =~ "Young Pyromancer"
        refute prompt =~ "Sol Ring"

        {:ok,
         %{
           "cards" => [
             %{"name" => "Young Pyromancer", "roles" => ["wincon"], "reasoning" => "fichas"}
           ]
         }}
      end)

      assert {:ok, %{rules: 1, ai: 1}} = Cards.classify_all([sol_ring, pyromancer])

      assert [%{kind: :ramp, source: :rule}] = Cards.roles_for(sol_ring)
      assert [%{kind: :wincon, source: :ai}] = Cards.roles_for(pyromancer)
    end

    test "does not call the model at all when the rules cover everything" do
      # verify_on_exit! fails the test if the mock is called.
      sol_ring = insert_fixture("sol_ring")
      cultivate = insert_fixture("cultivate")

      assert {:ok, %{rules: 2, ai: 0}} = Cards.classify_all([sol_ring, cultivate])
    end

    test "an AI failure does not lose the roles the rules already found" do
      sol_ring = insert_fixture("sol_ring")
      pyromancer = insert_fixture("young_pyromancer")

      expect(Deckex.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:error, Error.new(:ai_timeout, "estourou")}
      end)

      assert {:error, %Error{code: :ai_timeout}} = Cards.classify_all([sol_ring, pyromancer])

      # The rule pass ran first and its work is committed.
      assert [%{kind: :ramp, source: :rule}] = Cards.roles_for(sol_ring)
    end
  end
end
