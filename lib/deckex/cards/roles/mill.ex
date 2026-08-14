defmodule Deckex.Cards.Roles.Mill do
  @moduledoc """
  The `:mill` rule: putting cards from an **opponent's** library into their
  graveyard.

  Self-mill is deliberately excluded. A deck that mills itself is a graveyard
  build-around — the reference deck is one — while milling an opponent is a
  tactic aimed at a person, which is why an owner may want to avoid it.
  Counting the two together would let "evitar mill" cut the engine out of a
  graveyard deck.

  The distinction is free because of templating: modern oracle text names the
  victim for targeted mill (`Target player mills three cards`) and omits the
  subject entirely for self-mill (`mill three cards`). The catalogue always
  stores current oracle text, so pre-2021 wording never reaches this rule.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch

  @opponent_mill ~r/(target player|target opponent|each opponent|each player|opponents?) mills?/i

  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    body = card.oracle_text || ""

    if body =~ @opponent_mill do
      [RoleMatch.new(:mill, :high, "moe biblioteca alheia")]
    else
      []
    end
  end
end
