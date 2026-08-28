defmodule Deckex.Optimizations.CurationTest do
  use ExUnit.Case, async: true

  alias Deckex.Consults.Vacancy
  alias Deckex.Consults.Vacancy.Candidate
  alias Deckex.Optimizations.Curation
  alias Deckex.Optimizations.OptimizationStep

  defp vacancy(action, index, opts \\ []) do
    %Vacancy{
      key: Vacancy.key(action, index),
      action: action,
      index: index,
      grupo: opts[:grupo] || "Ramp",
      vaga: Keyword.get(opts, :vaga, "Falta aceleração de 2 mana."),
      reserve?: opts[:reserve?] || false,
      candidatos:
        Enum.map(opts[:cards] || ["Sol Ring", "Arcane Signet"], fn name ->
          %Candidate{name: name, porque: "porque #{name}", resolved?: true}
        end)
    }
  end

  defp step(selections \\ %{}, kind \\ :cardapio) do
    %OptimizationStep{kind: kind, selections: selections}
  end

  describe "decision/2" do
    test "a skip and an undecided vacancy are different answers" do
      vaga = vacancy(:add, 0)

      assert Curation.decision(step(), vaga) == :undecided
      assert Curation.decision(step(%{"add:0" => nil}), vaga) == nil
      assert Curation.decision(step(%{"add:0" => "Sol Ring"}), vaga) == "Sol Ring"
    end
  end

  describe "put/3" do
    test "records a choice, and a second click on the same card becomes a skip" do
      vaga = vacancy(:add, 0)

      selections = Curation.put(step(), vaga, "Sol Ring")
      assert selections == %{"add:0" => "Sol Ring"}

      assert Curation.put(step(selections), vaga, "Sol Ring") == %{"add:0" => nil}
    end

    test "clicking the other candidate switches rather than skips" do
      vaga = vacancy(:add, 0)
      chosen = step(%{"add:0" => "Sol Ring"})

      assert Curation.put(chosen, vaga, "Arcane Signet") == %{"add:0" => "Arcane Signet"}
    end

    test "clear/2 puts it back to undecided, which a skip is not" do
      vaga = vacancy(:add, 0)

      assert Curation.clear(step(%{"add:0" => nil}), vaga) == %{}
    end
  end

  describe "chosen/2" do
    test "builds suggestions cuts-first, so a freed slot is counted before the adds" do
      vacancies = [vacancy(:add, 0), vacancy(:cut, 0, cards: ["Forest"])]
      step = step(%{"add:0" => "Sol Ring", "cut:0" => "Forest"})

      assert [cut, add] = Curation.chosen(step, vacancies)
      assert cut.action == :cut
      assert add.action == :add
    end

    test "the reason carries the need and the card, and the group rides along" do
      vacancies = [vacancy(:add, 0, grupo: "Ramp", vaga: "Sua curva quer 5 peças de 2.")]

      assert [add] = Curation.chosen(step(%{"add:0" => "Sol Ring"}), vacancies)
      assert add.reason == "Sua curva quer 5 peças de 2. — porque Sol Ring"
      assert add.addresses == "Ramp"
    end

    test "a vacancy with no need falls back to the candidate's own sentence" do
      vacancies = [vacancy(:add, 0, vaga: "")]

      assert [add] = Curation.chosen(step(%{"add:0" => "Sol Ring"}), vacancies)
      assert add.reason == "porque Sol Ring"
    end

    test "skipped and undecided vacancies produce nothing" do
      vacancies = [vacancy(:add, 0), vacancy(:add, 1)]

      assert Curation.chosen(step(%{"add:0" => nil}), vacancies) == []
    end

    test "a selection naming a card the vacancy no longer offers is dropped, not raised" do
      vacancies = [vacancy(:add, 0, cards: ["Sol Ring"])]

      assert Curation.chosen(step(%{"add:0" => "Mana Crypt"}), vacancies) == []
    end

    test "carries the catalogue join through, so the audit sees a resolved card" do
      vacancies = [vacancy(:add, 0)]

      assert [add] = Curation.chosen(step(%{"add:0" => "Sol Ring"}), vacancies)
      assert add.resolved?
    end
  end

  describe "net/2 and count/3" do
    test "cards in minus cards out" do
      vacancies = [
        vacancy(:cut, 0, cards: ["Forest"]),
        vacancy(:add, 0),
        vacancy(:add, 1, cards: ["Cultivate"])
      ]

      step = step(%{"cut:0" => "Forest", "add:0" => "Sol Ring", "add:1" => "Cultivate"})

      assert Curation.net(step, vacancies) == 1
      assert Curation.count(step, vacancies, 100) == 101
    end

    test "an untouched board moves nothing" do
      assert Curation.net(step(), [vacancy(:add, 0)]) == 0
    end
  end

  describe "the reserve" do
    test "stays folded away until the count needs it" do
      vacancies = [
        vacancy(:cut, 0, cards: ["Forest"]),
        vacancy(:cut, 1, reserve?: true),
        vacancy(:add, 0)
      ]

      refute Curation.reserve_open?(step(), vacancies)
      assert Curation.visible(step(), vacancies) |> length() == 2
    end

    test "opens by itself the moment he is carrying more entries than cuts" do
      vacancies = [vacancy(:cut, 1, reserve?: true), vacancy(:add, 0)]
      carrying = step(%{"add:0" => "Sol Ring"})

      assert Curation.reserve_open?(carrying, vacancies)
      assert Curation.visible(carrying, vacancies) == vacancies
    end

    test "stays open once a reserve vacancy has been answered" do
      vacancies = [vacancy(:cut, 1, reserve?: true, cards: ["Forest"])]
      answered = step(%{"cut:1" => "Forest"})

      assert Curation.reserve_open?(answered, vacancies)
    end
  end

  describe "undecided/2" do
    test "counts only the vacancies with no answer of any kind" do
      vacancies = [vacancy(:add, 0), vacancy(:add, 1), vacancy(:add, 2)]

      assert Curation.undecided(step(%{"add:0" => "Sol Ring", "add:1" => nil}), vacancies) == 1
    end
  end

  describe "blocker/3" do
    test "refuses a cardápio that chose nothing — it would spend the critic for nothing" do
      assert Curation.blocker(step(), [vacancy(:add, 0)], 100) =~ "ainda não escolheu nada"
    end

    test "lets an empty critic's board through — that is him declining the corrections" do
      assert Curation.blocker(step(%{}, :critico), [vacancy(:add, 0)], 100) == nil
    end

    test "the count never blocks — off 100 is the balance stages' job" do
      # The owner chooses freely; the copy he leaves at 102 is what the
      # closing stages exist to settle, informed by every decision he made.
      vacancies = [vacancy(:add, 0), vacancy(:add, 1, cards: ["Cultivate"])]
      step = step(%{"add:0" => "Sol Ring", "add:1" => "Cultivate"})

      assert Curation.blocker(step, vacancies, 100) == nil

      assert Curation.blocker(
               step(%{"cut:0" => "Forest"}),
               [vacancy(:cut, 0, cards: ["Forest"])],
               100
             ) == nil
    end

    test "lets a balanced swap through, however small" do
      vacancies = [vacancy(:cut, 0, cards: ["Forest"]), vacancy(:add, 0)]
      step = step(%{"cut:0" => "Forest", "add:0" => "Sol Ring"})

      assert Curation.blocker(step, vacancies, 100) == nil
    end

    test "a sandbox that starts off 100 has to be walked back to it" do
      vacancies = [vacancy(:cut, 0, cards: ["Forest"])]
      step = step(%{"cut:0" => "Forest"})

      assert Curation.blocker(step, vacancies, 101) == nil
    end
  end
end
