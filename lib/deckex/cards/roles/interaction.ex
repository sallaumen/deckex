defmodule Deckex.Cards.Roles.Interaction do
  @moduledoc """
  Rules for the roles that answer an opponent: `:counter`, `:spot_removal`,
  `:board_wipe` and `:protection`.

  `:counter` and `:spot_removal` are deliberately separate and must never be
  summed into one "interaction" number. A counterspell is a dead card once the
  threat has resolved; against an aggressive deck only the answers that address
  a permanent already on the battlefield count.

  The wipe rules exclude "each creature **you control**" — a pump clause on a
  removal spell (`Overwhelming Victory`) otherwise reads as a board wipe.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch

  @counter ~r/counter target/i

  @destroys_all ~r/(destroy|exile) all\b/i

  # Mass damage, but not the "each creature you control" pump clause.
  @damages_all ~r/damage to each creature(?! you control)/i

  @sacrifice_all ~r/each (player|opponent) sacrifices/i

  @spot ~r/(destroy|exile) target|damage to target (creature|permanent|planeswalker)|damage to any target/i

  @protection ~r/\b(hexproof|indestructible|shroud|protection from|ward)\b/i

  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    body = card.oracle_text || ""

    counter(body) ++ mass_or_spot(body) ++ protection(body)
  end

  defp counter(body) do
    if body =~ @counter,
      do: [RoleMatch.new(:counter, :high, "contra-magia (\"counter target\")")],
      else: []
  end

  # A card is a wipe or spot removal, never both: the wipe clause on a sweeper
  # would otherwise also trip the spot pattern via a secondary mode.
  defp mass_or_spot(body) do
    cond do
      wipe?(body) -> [RoleMatch.new(:board_wipe, :high, "atinge todas as criaturas")]
      body =~ @spot -> [RoleMatch.new(:spot_removal, :high, "remove um alvo único")]
      true -> []
    end
  end

  defp wipe?(body) do
    body =~ @destroys_all or body =~ @damages_all or body =~ @sacrifice_all
  end

  defp protection(body) do
    if body =~ @protection do
      [RoleMatch.new(:protection, :medium, "concede proteção (hexproof/indestructible/ward)")]
    else
      []
    end
  end
end
