defmodule Deckex.Consults.Visions do
  @moduledoc """
  Reads a `:visao` answer into `Deckex.Consults.Vision` structs.

  Two jobs the model must not do for itself: pricing the key cards (the price
  law) and deciding whether a proposed commander is allowed (the legality law).
  Both happen here, from the catalogue, when the visions are **shown** — so the
  owner never picks a direction and only then learns its commander was refused.
  """

  alias Deckex.Cards
  alias Deckex.Cards.Card
  alias Deckex.Consults.Consult
  alias Deckex.Consults.Vision

  @doc "The visions in a consult's answer, priced and validated."
  @spec for_consult(Consult.t(), [String.t()]) :: [Vision.t()]
  def for_consult(%Consult{} = consult, color_identity) do
    consult |> rows() |> Enum.map(&build(&1, color_identity))
  end

  @doc """
  Every card name a vision answer mentions, for the catalogue to fetch.

  Without this the key cards would never be resolved and every vision would
  show a price of zero — the answer has no cuts and no adds, so the ordinary
  suggestion path finds nothing in it.
  """
  @spec card_names(Consult.t()) :: [String.t()]
  def card_names(%Consult{} = consult) do
    consult
    |> rows()
    |> Enum.flat_map(&(List.wrap(&1["cartas_chave"]) ++ List.wrap(&1["comandante"])))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Why this card may not be this deck's commander, or nil.

  The identity must match **exactly**. A narrower commander would make every
  card outside its identity illegal at once — a cascade of cuts made for a
  reason that has nothing to do with the deck being better.
  """
  @spec commander_problem(Card.t() | nil, [String.t()]) :: String.t() | nil
  def commander_problem(nil, _identity), do: "não achei essa carta na Scryfall"

  def commander_problem(%Card{} = card, identity) do
    cond do
      not card.commander_legal ->
        "não é legal em Commander"

      not can_be_commander?(card) ->
        "não pode ser comandante — não é criatura lendária"

      Enum.sort(card.color_identity) != Enum.sort(identity) ->
        "não tem a mesma identidade de cor do deck — trocar tornaria ilegais as cartas que ficam de fora"

      true ->
        nil
    end
  end

  defp rows(%Consult{response: response}) when is_map(response) do
    response |> Map.get("visoes") |> List.wrap()
  end

  defp rows(_no_answer), do: []

  defp build(row, color_identity) do
    cartas = Enum.map(List.wrap(row["cartas_chave"]), &card_row/1)
    commander_name = blank_to_nil(row["comandante"])
    commander = commander_name && Cards.get_by_name(commander_name)

    %Vision{
      nome: row["nome"] || "",
      eixo: row["eixo"] || "",
      tese: row["tese"] || "",
      custo: row["custo"] || "",
      cartas: cartas,
      total_usd: total(cartas),
      comandante: commander,
      comandante_nome: commander_name,
      comandante_problem: commander_name && commander_problem(commander, color_identity)
    }
  end

  defp card_row(name) do
    card = Cards.get_by_name(name)

    %{name: name, card: card, price_usd: card && card.price_usd}
  end

  defp total(cartas) do
    cartas
    |> Enum.map(& &1.price_usd)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1))
  end

  # A legendary creature, or a card that says so itself — the backgrounds and
  # the handful of non-creatures with the clause.
  defp can_be_commander?(%Card{} = card) do
    type_line = card.type_line || ""
    text = card.oracle_text || ""

    (String.contains?(type_line, "Legendary") and String.contains?(type_line, "Creature")) or
      String.contains?(text, "can be your commander")
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
