defmodule Deckex.Optimizations.ShoppingListTest do
  use Deckex.DataCase, async: true

  alias Deckex.CatalogueFixture
  alias Deckex.Decks
  alias Deckex.Optimizations
  alias Deckex.Optimizations.Optimization

  setup do
    CatalogueFixture.seed!(~w(sol_ring forest cultivate counterspell))

    {:ok, deck} =
      Decks.import_from_text("1 Sol Ring\n4 Forest", %{name: "Deck da Compra", source: :paste})

    %{deck: deck}
  end

  defp run(applied) do
    %Optimization{steps: [%{applied: applied, status: :done}]}
  end

  defp add(card, reason \\ "porque sim"),
    do: %{"action" => "add", "card" => card, "reason" => reason}

  defp cut(card), do: %{"action" => "cut", "card" => card, "reason" => "sai"}

  describe "shopping_list/2" do
    test "lists the adds with their prices and totals them", %{deck: deck} do
      list = Optimizations.shopping_list(run([add("Cultivate"), add("Counterspell")]), deck)

      assert Enum.map(list.cards, & &1.name) == ["Counterspell", "Cultivate"]
      assert Decimal.gt?(list.total_usd, Decimal.new(0))
      assert list.unpriced == 0
    end

    # The whole reason this is not just the diff: a card already applied to the
    # real deck is a change the owner made, not a card he still has to buy.
    test "skips what the real deck already holds", %{deck: deck} do
      list = Optimizations.shopping_list(run([add("Cultivate"), add("Sol Ring")]), deck)

      assert Enum.map(list.cards, & &1.name) == ["Cultivate"]
    end

    test "a card that entered and left is not on the list", %{deck: deck} do
      list = Optimizations.shopping_list(run([add("Cultivate"), cut("Cultivate")]), deck)

      assert list.cards == []
      assert Decimal.equal?(list.total_usd, Decimal.new(0))
    end

    test "cuts are never purchases", %{deck: deck} do
      list = Optimizations.shopping_list(run([cut("Sol Ring")]), deck)

      assert list.cards == []
    end

    # Guessing what an unpriced card costs to make the arithmetic tidy is the
    # invention this app refuses everywhere else.
    test "an unpriced card is listed and left out of the total", %{deck: deck} do
      card = Deckex.Cards.get_by_name("Cultivate")
      {:ok, _} = card |> Ecto.Changeset.change(price_usd: nil) |> Repo.update()

      list = Optimizations.shopping_list(run([add("Cultivate")]), deck)

      assert [%{name: "Cultivate", price_usd: nil}] = list.cards
      assert list.unpriced == 1
      assert Decimal.equal?(list.total_usd, Decimal.new(0))
    end

    test "a card the catalogue never saw still makes the list", %{deck: deck} do
      list = Optimizations.shopping_list(run([add("Carta Ignota")]), deck)

      assert [%{name: "Carta Ignota", card: nil, price_usd: nil}] = list.cards
      assert list.unpriced == 1
    end
  end

  describe "shopping_list_text/2" do
    test "one card per line, in the format a shop's bulk box reads", %{deck: deck} do
      text = Optimizations.shopping_list_text(run([add("Cultivate"), add("Counterspell")]), deck)

      assert text == "1 Counterspell\n1 Cultivate\n"
    end

    test "nothing to buy is an empty string, not a lonely newline", %{deck: deck} do
      assert Optimizations.shopping_list_text(run([cut("Sol Ring")]), deck) == ""
    end
  end
end
