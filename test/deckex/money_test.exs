defmodule Deckex.MoneyTest do
  use Deckex.DataCase, async: true

  alias Deckex.AI
  alias Deckex.Money
  alias Deckex.Moxfield.Http
  alias Deckex.Settings

  describe "to_brl/1" do
    test "converts at the configured rate" do
      {:ok, _value} = Settings.put(:usd_to_brl, 5.0)

      assert Decimal.equal?(Money.to_brl(Decimal.new("10.00")), Decimal.new("50.00"))
    end

    test "a card with no price stays without one" do
      assert Money.to_brl(nil) == nil
    end
  end

  describe "formatting" do
    test "prints dollars" do
      assert Money.usd(Decimal.new("25.50")) == "US$ 25,50"
    end

    test "prints reais" do
      {:ok, _value} = Settings.put(:usd_to_brl, 5.0)

      assert Money.brl(Decimal.new("10.00")) == "R$ 50,00"
    end

    test "an unknown price says so rather than printing zero" do
      assert Money.usd(nil) == "—"
      assert Money.brl(nil) == "—"
    end
  end

  describe "settings reach the ports" do
    test "the AI model follows the stored setting" do
      assert AI.model() == "sonnet"

      {:ok, _value} = Settings.put(:claude_model, "opus")
      assert AI.model() == "opus"
    end

    test "the Moxfield User-Agent follows the stored setting" do
      {:ok, _value} = Settings.put(:moxfield_user_agent, "deckex/1.0 (approved by moxfield)")

      assert Http.user_agent() == "deckex/1.0 (approved by moxfield)"
    end
  end
end
