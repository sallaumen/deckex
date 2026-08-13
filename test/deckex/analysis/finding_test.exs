defmodule Deckex.Analysis.FindingTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Finding

  defp finding(severity) do
    Finding.new("x.y", severity, :mana_ramp, "Título", "Detalhe")
  end

  describe "new/6" do
    test "carries everything a user needs to act" do
      finding =
        Finding.new("mana.ramp_low", :warning, :mana_ramp, "Pouco ramp", "Só 6 peças.",
          evidence: %{ramp: 6, target: 10},
          card_names: ["Sol Ring"]
        )

      assert %Finding{
               code: "mana.ramp_low",
               severity: :warning,
               lens: :mana_ramp,
               evidence: %{ramp: 6, target: 10},
               card_names: ["Sol Ring"]
             } = finding
    end

    test "defaults evidence and card names" do
      assert %Finding{evidence: %{}, card_names: []} = finding(:info)
    end

    test "rejects a severity outside the vocabulary" do
      assert_raise FunctionClauseError, fn ->
        Finding.new("x.y", :apocalyptic, :mana_ramp, "t", "d")
      end
    end

    test "rejects a lens outside the vocabulary" do
      assert_raise FunctionClauseError, fn ->
        Finding.new("x.y", :warning, :vibes, "t", "d")
      end
    end
  end

  describe "sort/1" do
    test "puts critical first and info last" do
      sorted = Finding.sort([finding(:info), finding(:critical), finding(:warning)])

      assert Enum.map(sorted, & &1.severity) == [:critical, :warning, :info]
    end
  end

  describe "critical?/1" do
    test "is true only for critical" do
      assert Finding.critical?(finding(:critical))
      refute Finding.critical?(finding(:warning))
    end
  end
end
