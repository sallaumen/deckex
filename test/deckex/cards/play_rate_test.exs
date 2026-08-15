defmodule Deckex.Cards.PlayRateTest do
  use ExUnit.Case, async: true

  alias Deckex.Cards.Card
  alias Deckex.Cards.PlayRate

  describe "band/1" do
    test "the bands, at their edges" do
      assert PlayRate.band(1) == :staple
      assert PlayRate.band(500) == :staple
      assert PlayRate.band(501) == :common
      assert PlayRate.band(2_000) == :common
      assert PlayRate.band(2_001) == :niche
      assert PlayRate.band(10_000) == :niche
      assert PlayRate.band(10_001) == :fringe
    end

    test "no rank is unknown, never fringe — silence is not evidence" do
      assert PlayRate.band(nil) == :unknown
      assert PlayRate.label(nil) == "sem dado de uso"
      refute PlayRate.worth_a_look?(nil)
    end

    test "reads the rank off a card" do
      assert PlayRate.band(%Card{edhrec_rank: 3}) == :staple
      assert PlayRate.band(%Card{edhrec_rank: nil}) == :unknown
    end
  end

  # The whole point, in one test: the cheapest suggestion in the owner's real
  # runs was one of the best cards in the format, and one of the priciest was
  # nearly unplayed. Price told him nothing; this tells him something.
  describe "what price could not say" do
    test "Arcane Signet at two reais is a staple; Vexing Shusher at thirty-six is not" do
      assert PlayRate.band(3) == :staple
      assert PlayRate.band(5_346) == :niche
      assert PlayRate.worth_a_look?(10_632)
    end
  end

  describe "position/1" do
    test "thousands get a separator, because 10632 and 1632 are one glance apart" do
      assert PlayRate.position(3) == "#3"
      assert PlayRate.position(704) == "#704"
      assert PlayRate.position(1_632) == "#1.632"
      assert PlayRate.position(10_632) == "#10.632"
      assert PlayRate.position(nil) == nil
    end
  end

  describe "sentence/1" do
    test "the number and what it counts, together" do
      assert PlayRate.sentence(3) == "#3 em uso no Commander — carta de base do formato"
      assert PlayRate.sentence(nil) == "sem dado de uso"
    end
  end
end
