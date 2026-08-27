defmodule Deckex.Consults.VacanciesTest do
  use Deckex.DataCase, async: true

  alias Deckex.CatalogueFixture
  alias Deckex.Consults.Consult
  alias Deckex.Consults.Vacancies

  defp cardapio(cortes, adicoes) do
    %Consult{
      lens: :cardapio,
      response: %{"leitura" => "Leitura.", "cortes" => cortes, "adicoes" => adicoes}
    }
  end

  defp vacancy(grupo, vaga, cards) do
    %{
      "grupo" => grupo,
      "vaga" => vaga,
      "candidatos" => Enum.map(cards, &%{"carta" => &1, "porque" => "porque #{&1}"})
    }
  end

  describe "for_consult/2 on a cardápio" do
    test "reads cuts first, keyed by action and position" do
      consult =
        cardapio(
          [vacancy("Terreno lento", "Quatro terrenos entram virados.", ["Forest"])],
          [vacancy("Ramp", "Sua curva quer mais aceleração.", ["Sol Ring", "Cultivate"])]
        )

      assert [corte, entrada] = Vacancies.for_consult(consult, %{})

      assert corte.action == :cut
      assert corte.key == "cut:0"
      assert corte.grupo == "Terreno lento"
      assert corte.vaga == "Quatro terrenos entram virados."

      assert entrada.action == :add
      assert entrada.key == "add:0"
      assert Enum.map(entrada.candidatos, & &1.name) == ["Sol Ring", "Cultivate"]
      assert Enum.map(entrada.candidatos, & &1.porque) == ["porque Sol Ring", "porque Cultivate"]
    end

    test "joins candidates to the catalogue, and leaves the unknown ones unresolved" do
      CatalogueFixture.seed!(~w(sol_ring))

      consult = cardapio([], [vacancy("Ramp", "Falta ramp.", ["Sol Ring", "Carta Inventada"])])

      assert [entrada] = Vacancies.for_consult(consult, %{})
      assert [known, unknown] = entrada.candidatos

      assert known.resolved?
      assert known.card.name == "Sol Ring"
      assert known.price_usd == known.card.price_usd

      refute unknown.resolved?
      assert is_nil(unknown.card)
    end

    test "flags cut vacancies past the principal count as reserve" do
      cortes = Enum.map(1..4, &vacancy("Genérico", "Vaga #{&1}", ["Forest"]))

      assert vacancies = Vacancies.for_consult(cardapio(cortes, []), %{"vagas_corte" => 2})
      assert Enum.map(vacancies, & &1.reserve?) == [false, false, true, true]
    end

    test "an add vacancy is never reserve, whatever the cut count says" do
      adicoes = Enum.map(1..3, &vacancy("Ramp", "Vaga #{&1}", ["Sol Ring"]))

      assert vacancies = Vacancies.for_consult(cardapio([], adicoes), %{"vagas_corte" => 1})
      refute Enum.any?(vacancies, & &1.reserve?)
    end

    test "drops a vacancy whose candidates are all unusable" do
      consult =
        cardapio(
          [%{"grupo" => "Vazio", "vaga" => "Nada aqui.", "candidatos" => [%{"carta" => ""}]}],
          [vacancy("Ramp", "Falta ramp.", ["Sol Ring"])]
        )

      assert [only] = Vacancies.for_consult(consult, %{})
      assert only.action == :add
    end

    test "the same card twice in one vacancy is one candidate" do
      consult = cardapio([], [vacancy("Ramp", "Falta ramp.", ["Sol Ring", "sol ring"])])

      assert [entrada] = Vacancies.for_consult(consult, %{})
      assert length(entrada.candidatos) == 1
    end

    test "an answer with no vacancies reads as none, not as a crash" do
      assert Vacancies.for_consult(%Consult{lens: :cardapio, response: %{}}, %{}) == []
      assert Vacancies.for_consult(%Consult{lens: :cardapio, response: nil}, %{}) == []
      assert Vacancies.for_consult(nil, %{}) == []
    end
  end

  describe "for_consult/2 on a critic" do
    test "every correction becomes a vacancy of one, offered rather than applied" do
      consult = %Consult{
        lens: :critico,
        response: %{
          "veredito" => "Ficou melhor.",
          "cuts" => [%{"card" => "Forest", "reason" => "sobra terreno"}],
          "adds" => [%{"card" => "Sol Ring", "reason" => "falta ramp"}]
        }
      }

      assert [corte, entrada] = Vacancies.for_consult(consult, %{})

      assert corte.action == :cut
      assert corte.grupo == "Correção do crítico"
      assert [%{name: "Forest", porque: "sobra terreno"}] = corte.candidatos

      assert entrada.action == :add
      assert [%{name: "Sol Ring"}] = entrada.candidatos
    end
  end

  describe "card_names/1" do
    test "names every candidate, so the catalogue can fetch them" do
      consult =
        cardapio(
          [vacancy("Terreno", "Sobra terreno.", ["Forest"])],
          [vacancy("Ramp", "Falta ramp.", ["Sol Ring", "Cultivate"])]
        )

      assert Enum.sort(Vacancies.card_names(consult)) == ["Cultivate", "Forest", "Sol Ring"]
    end

    test "says nothing about a lens that answers in cuts and adds" do
      consult = %Consult{lens: :critico, response: %{"adds" => [%{"card" => "Sol Ring"}]}}

      assert Vacancies.card_names(consult) == []
    end
  end

  describe "slot_counts/1" do
    test "defaults when the contract predates the fields" do
      assert Vacancies.slot_counts(nil) == %{cuts: 10, adds: 20}
      assert Vacancies.slot_counts(%{}) == %{cuts: 10, adds: 20}
    end

    test "reads the numbers the launch modal wrote, as text or as integers" do
      assert Vacancies.slot_counts(%{"vagas_corte" => 6, "vagas_entrada" => 12}) ==
               %{cuts: 6, adds: 12}

      assert Vacancies.slot_counts(%{"vagas_corte" => "6", "vagas_entrada" => "12"}) ==
               %{cuts: 6, adds: 12}
    end

    test "refuses a number that would make the board empty" do
      assert Vacancies.slot_counts(%{"vagas_corte" => 0, "vagas_entrada" => -3}) ==
               %{cuts: 10, adds: 20}
    end
  end
end
