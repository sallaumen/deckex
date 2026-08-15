defmodule Deckex.Optimizations.BalanceTest do
  use ExUnit.Case, async: true

  alias Deckex.Optimizations.Balance

  describe "drift/1 — what a stage is asked for" do
    test "capped at two either way: the gap closes over stages, not in one" do
      assert Balance.drift(105) == -2
      assert Balance.drift(120) == -2
      assert Balance.drift(95) == 2
      assert Balance.drift(60) == 2
    end

    test "a small gap is asked for exactly" do
      assert Balance.drift(101) == -1
      assert Balance.drift(99) == 1
      assert Balance.drift(100) == 0
    end
  end

  describe "surplus/3 — what the engine sends back from an ordinary stage" do
    # A stage gets a card or two of slack: forbidding a copy at exactly 100
    # from ever ending a stage at 101 is stricter than the owner asked for, and
    # costs the model the freedom to take two good cards now and pay next
    # stage. The closing stage is what guarantees the landing.
    test "a copy at 100 may breathe by two, not by three" do
      assert Balance.surplus(0, 100) == :none
      assert Balance.surplus(1, 100) == :none
      assert Balance.surplus(-2, 100) == :none
      assert Balance.surplus(3, 100) == {:add, 1}
      assert Balance.surplus(-3, 100) == {:cut, 1}
    end

    test "a copy over 100 may come back or hold, never run away" do
      assert Balance.surplus(-2, 105) == :none
      assert Balance.surplus(0, 105) == :none
      assert Balance.surplus(1, 105) == {:add, 1}
      assert Balance.surplus(4, 105) == {:add, 4}
    end

    test "a copy under 100 may grow, and may not sink further" do
      assert Balance.surplus(2, 95) == :none
      assert Balance.surplus(0, 95) == :none
      assert Balance.surplus(-1, 95) == {:cut, 1}
    end

    # A swap is not a drift. Judged card by card with cuts first, a deck 95
    # short would have every cut refused before reaching the adds paying for
    # them — which is the bug this function exists to not have.
    test "swapping any number of cards is always allowed" do
      for count <- [95, 100, 105] do
        assert Balance.surplus(0, count) == :none
      end
    end
  end

  describe "surplus/3 — the closing stage has no slack" do
    test "it lands on 100 or it is refused" do
      assert Balance.surplus(-5, 105, :closing) == :none
      assert Balance.surplus(-4, 105, :closing) == {:add, 1}
      assert Balance.surplus(-6, 105, :closing) == {:cut, 1}
    end

    test "the same from below" do
      assert Balance.surplus(3, 97, :closing) == :none
      assert Balance.surplus(2, 97, :closing) == {:cut, 1}
      assert Balance.surplus(4, 97, :closing) == {:add, 1}
    end

    test "a copy already at 100 may not be touched by the closing stage" do
      assert Balance.surplus(0, 100, :closing) == :none
      assert Balance.surplus(1, 100, :closing) == {:add, 1}
    end
  end

  describe "instruction/1 — what the briefing says" do
    test "names the number to end on, not merely the direction" do
      text = Balance.instruction(105)

      assert text =~ "105 cards"
      assert text =~ "It is 5 over."
      assert text =~ "end this stage at **103**"
      assert text =~ "2 more cut(s) than add(s)"
    end

    test "a short deck is asked to grow" do
      text = Balance.instruction(97)

      assert text =~ "It is 3 short."
      assert text =~ "end this stage at **99**"
      assert text =~ "2 more add(s) than cut(s)"
    end

    test "at 100 it asks for balance, not for movement" do
      text = Balance.instruction(100)

      assert text =~ "exactly 100"
      assert text =~ "one card in for every card out"
    end

    # A stage told to shed five at once stops choosing the worst five.
    test "it explicitly refuses to ask for the whole gap" do
      assert Balance.instruction(110) =~ "Do not try to close the whole gap in one stage"
    end
  end
end
