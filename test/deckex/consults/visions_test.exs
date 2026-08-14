defmodule Deckex.Consults.VisionsTest do
  use Deckex.DataCase, async: true

  alias Deckex.Cards
  alias Deckex.CatalogueFixture
  alias Deckex.Consults.Visions

  setup do
    CatalogueFixture.seed!(~w(sol_ring counterspell cultivate baral_chief_of_compliance))

    :ok
  end

  defp consult(visoes) do
    build(:consult, lens: :visao, status: :done, response: %{"visoes" => visoes})
  end

  defp vision(overrides) do
    Map.merge(
      %{
        "nome" => "Controle de Temur",
        "eixo" => "resiliencia",
        "tese" => "Trocar velocidade por respostas.",
        "custo" => "Perde os turnos rápidos.",
        "cartas_chave" => []
      },
      overrides
    )
  end

  test "the app prices the key cards from the catalogue" do
    [vision] =
      Visions.for_consult(
        consult([vision(%{"cartas_chave" => ["Sol Ring", "Counterspell"]})]),
        ~w(U R)
      )

    assert vision.nome == "Controle de Temur"
    assert length(vision.cartas) == 2
    assert Decimal.gt?(vision.total_usd, Decimal.new(0))
  end

  test "a card the catalogue does not know is listed without inventing a price" do
    [vision] =
      Visions.for_consult(consult([vision(%{"cartas_chave" => ["Carta Que Não Existe"]})]), ~w(U))

    assert [%{name: "Carta Que Não Existe", card: nil, price_usd: nil}] = vision.cartas
    assert Decimal.eq?(vision.total_usd, Decimal.new(0))
  end

  test "card names include the key cards and the commander, so the catalogue can fetch them" do
    names =
      Visions.card_names(
        consult([
          vision(%{"cartas_chave" => ["Cultivate"], "comandante" => "Baral, Chief of Compliance"})
        ])
      )

    assert "Cultivate" in names
    assert "Baral, Chief of Compliance" in names
  end

  test "a commander outside the deck's identity is refused, and the vision survives" do
    [vision] =
      Visions.for_consult(
        consult([vision(%{"comandante" => "Baral, Chief of Compliance"})]),
        ~w(G)
      )

    assert vision.comandante_problem =~ "identidade de cor"
    assert vision.nome == "Controle de Temur"
  end

  test "a commander with exactly the deck's identity is accepted" do
    [vision] =
      Visions.for_consult(
        consult([vision(%{"comandante" => "Baral, Chief of Compliance"})]),
        ~w(U)
      )

    assert vision.comandante_problem == nil
    assert vision.comandante.name == "Baral, Chief of Compliance"
  end

  test "a card that is not a legendary creature cannot be the commander" do
    assert Visions.commander_problem(Cards.get_by_name("Sol Ring"), []) =~
             "não pode ser comandante"
  end

  test "a name the catalogue never resolved is refused rather than assumed" do
    assert Visions.commander_problem(nil, ~w(U)) =~ "não achei"
  end

  test "an answer with no visions yields nothing rather than raising" do
    assert Visions.for_consult(build(:consult, lens: :visao, response: nil), ~w(U)) == []
  end
end
