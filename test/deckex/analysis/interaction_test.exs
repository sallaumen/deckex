defmodule Deckex.Analysis.InteractionTest do
  use ExUnit.Case, async: true

  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Interaction
  alias Deckex.AnalysisFixture

  # `opts` comes FIRST: AnalysisFixture reads with Keyword.get, which returns the
  # first occurrence, so an override has to precede the default it replaces.
  defp with_roles(role, n, opts) do
    for i <- 1..n do
      AnalysisFixture.entry(opts ++ [name: "#{role} #{i}", roles: [role], type_line: "Instant"])
    end
  end

  defp with_roles(role, n), do: with_roles(role, n, [])

  defp codes(entries, baselines \\ Baselines.default()) do
    entries
    |> AnalysisFixture.snapshot()
    |> Interaction.findings(baselines)
    |> Enum.map(& &1.code)
  end

  describe "measure/1" do
    test "counts each answer type separately" do
      entries =
        with_roles(:counter, 4) ++ with_roles(:spot_removal, 7) ++ with_roles(:board_wipe, 1)

      assert %{counters: 4, spot_removal: 7, board_wipes: 1} =
               entries |> AnalysisFixture.snapshot() |> Interaction.measure()
    end

    test "answers exclude counterspells — they cannot address a resolved threat" do
      entries = with_roles(:counter, 4) ++ with_roles(:spot_removal, 7)

      assert %{answers: 7} = entries |> AnalysisFixture.snapshot() |> Interaction.measure()
    end

    test "splits by speed" do
      entries =
        with_roles(:spot_removal, 3) ++ with_roles(:spot_removal, 2, type_line: "Sorcery")

      assert %{instant_speed: 3, sorcery_speed: 2} =
               entries |> AnalysisFixture.snapshot() |> Interaction.measure()
    end
  end

  describe "findings/2" do
    test "flags a deck with almost no interaction" do
      assert "interaction.total_low" in codes(with_roles(:counter, 2))
    end

    test "flags a deck with no sweeper at all" do
      assert "interaction.no_board_wipes" in codes(with_roles(:spot_removal, 10))
    end

    test "flags a deck with only one sweeper" do
      found = codes(with_roles(:spot_removal, 10) ++ with_roles(:board_wipe, 1))

      assert "interaction.board_wipes_low" in found
      refute "interaction.no_board_wipes" in found
    end

    test "does not flag a deck with enough sweepers" do
      found = codes(with_roles(:spot_removal, 10) ++ with_roles(:board_wipe, 2))

      refute "interaction.board_wipes_low" in found
      refute "interaction.no_board_wipes" in found
    end

    test "flags interaction that is mostly sorcery speed" do
      assert "interaction.sorcery_speed_heavy" in codes(
               with_roles(:spot_removal, 8, type_line: "Sorcery")
             )
    end

    test "flags a deck that cannot protect anything" do
      assert "interaction.no_protection" in codes(with_roles(:spot_removal, 10))
    end

    test "removal that only knows one shape is called out" do
      narrow =
        with_roles(:spot_removal, 5, oracle_text: "Destroy target creature.") ++
          with_roles(:protection, 2) ++ with_roles(:board_wipe, 2)

      assert "interaction.answers_too_narrow" in codes(narrow)
    end

    test "removal that answers any permanent is not" do
      flexible =
        with_roles(:spot_removal, 5, oracle_text: "Destroy target permanent.") ++
          with_roles(:protection, 2) ++ with_roles(:board_wipe, 2)

      refute "interaction.answers_too_narrow" in codes(flexible)
    end

    # Silence is not evidence of narrowness — the same rule that stops an
    # unpriced card being refused for being expensive.
    test "a card whose text we cannot read counts as neither" do
      refute "interaction.answers_too_narrow" in codes(with_roles(:spot_removal, 7))
    end

    test "a healthy answer suite produces no interaction findings" do
      entries =
        with_roles(:spot_removal, 7) ++ with_roles(:board_wipe, 2) ++ with_roles(:protection, 2)

      assert codes(entries) == []
    end
  end
end
