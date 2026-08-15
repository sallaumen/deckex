defmodule Deckex.BudgetTest do
  use Deckex.DataCase, async: true

  alias Deckex.Analysis.CardEntry
  alias Deckex.Budget
  alias Deckex.Settings

  # At the default rate of 5.4, US$ 100 is R$ 540 and US$ 50 is R$ 270.
  defp entry(usd, quantity \\ 1) do
    CardEntry.new(build(:card, price_usd: usd && Decimal.new(usd)), quantity, [])
  end

  defp policy, do: Budget.policy()

  describe "policy/0" do
    test "reads the owner's four numbers" do
      assert %{
               expensive: %{threshold: 400, max: 10},
               exception: %{threshold: 600, max: 2}
             } = policy()
    end

    test "zero switches a tier off, the convention every other number here uses" do
      {:ok, _v} = Settings.put(:expensive_card_max, 0)

      assert policy().expensive.max == nil
    end
  end

  describe "tier/2" do
    test "the two lines, and the ordinary card between them" do
      # R$ 216, R$ 540 and R$ 3.780.
      assert Budget.tier(Decimal.new("40"), policy()) == nil
      assert Budget.tier(Decimal.new("100"), policy()) == :expensive
      assert Budget.tier(Decimal.new("700"), policy()) == :exception
    end

    # Refusing a card because we do not know what it costs would be inventing
    # a fact about it — the same rule the ceiling already follows.
    test "no price is no tier" do
      assert Budget.tier(nil, policy()) == nil
    end

    test "a tier that is switched off catches nothing" do
      {:ok, _v} = Settings.put(:expensive_card_brl, 0)

      assert Budget.tier(Decimal.new("100"), policy()) == nil
    end
  end

  describe "occupancy/2" do
    test "counts what the deck already holds, by tier" do
      # R$ 540 and R$ 567 are expensive; R$ 3.780 is an exception, which counts
      # as expensive too.
      entries = [entry("100"), entry("105"), entry("700"), entry("5"), entry(nil)]

      assert Budget.occupancy(entries, policy()) == %{expensive: 3, exception: 1}
    end

    test "counts copies, not names" do
      assert Budget.occupancy([entry("100", 3)], policy()).expensive == 3
    end
  end

  describe "room?/3 and charge/3" do
    test "an exception takes one of each: it is an expensive card that also broke the ceiling" do
      charged = Budget.charge(%{expensive: 0, exception: 0}, :exception, 1)

      assert charged == %{expensive: 1, exception: 1}
    end

    test "the slots run out" do
      full = %{expensive: 0, exception: 2}

      refute Budget.room?(full, :exception, policy())
      assert Budget.room?(%{expensive: 0, exception: 1}, :exception, policy())
    end

    # Cutting an expensive card and adding another has not changed the shape of
    # the deck, and an engine that only counted upwards would say it had.
    test "a cut gives the slot back" do
      assert Budget.charge(%{expensive: 4, exception: 1}, :expensive, -1).expensive == 3
    end

    test "never below zero — a cut of a card the count never saw is not a credit" do
      assert Budget.charge(%{expensive: 0, exception: 0}, :expensive, -1).expensive == 0
    end

    test "a tier with no maximum always has room" do
      {:ok, _v} = Settings.put(:exception_card_max, 0)

      assert Budget.room?(%{expensive: 0, exception: 99}, :exception, policy())
    end

    test "an ordinary card charges nothing and always fits" do
      assert Budget.room?(%{expensive: 10, exception: 2}, nil, policy())
      assert Budget.charge(%{expensive: 1, exception: 0}, nil, 1) == %{expensive: 1, exception: 0}
    end
  end

  describe "from_contract/1" do
    # A run that started under one set of numbers must finish under them.
    test "a frozen shape round-trips" do
      frozen = Budget.to_contract(policy())

      assert Budget.from_contract(frozen) == policy()
    end

    # Dropping the guard for old runs would be the worst of both: no limit, and
    # no sign that there ever was one.
    test "a run from before the shape existed uses today's" do
      assert Budget.from_contract(nil) == policy()
    end
  end
end
