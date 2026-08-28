defmodule Deckex.Cards.Roles.Reading do
  @moduledoc """
  The text a rule is allowed to read: the card's own words, never the reminder.

  Reminder text — the parenthetical the printed card sets in italics — repeats
  a rule the game already has, and classifying from it invents roles wholesale.
  Measured across the real catalogue the day the draw rule got eyes: a cycling
  Triome became a draw engine ("Discard this card: Draw a card."), Reiterate
  became one through Buyback's "put this card into your hand", and Lurrus
  through the companion note. Four of the eighty-eight changes were reminders,
  and all four were wrong.

  Every classifier reads through this function, so the exclusion is a property
  of the engine and not a fix repeated six times.
  """

  alias Deckex.Cards.Card

  @reminder ~r/\([^)]*\)/

  @doc "The oracle text with every parenthetical removed, never nil."
  @spec body(Card.t()) :: String.t()
  def body(%Card{oracle_text: text}), do: Regex.replace(@reminder, text || "", "")
end
