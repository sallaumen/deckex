defmodule Deckex.Cards.Roles.Bracket do
  @moduledoc """
  Rules for the two roles the Commander Brackets ask about by name:
  `:mass_land_denial` and `:extra_turn`.

  Both push a deck to bracket 4 on their own, so both are written narrowly —
  a false positive here does not merely mislabel a card, it relabels the whole
  deck.

  **Mass land denial** is destroying or sacrificing *lands*, plural, across the
  table. Strip Mine destroys one land and is not mass denial; Armageddon is.
  Winter Orb does not destroy anything, so it is not denial either — it is
  stax, which the existing rules already catch and which the brackets treat
  separately.

  **Extra turns** is the printed effect. The brackets forbid *chaining* them,
  which a decklist cannot prove — a single Time Warp is legal in bracket 2 and
  a deck built to loop it is not. So this rule reports the card and the
  bracket lens asks the model whether the deck chains them.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch

  # "destroy all lands", "destroy each land", and the sacrifice variants that
  # hit every player. `all|each` after the verb keeps Strip Mine out, and
  # `[^.]*?` crosses the list in "destroy all artifacts, creatures, and lands"
  # without ever leaving the sentence — Jokulhaups is mass land denial and a
  # first draft that stopped at the comma missed it.
  @destroys_all_lands ~r/(destroy|exile) (all|each)\b[^.]*?\blands?\b/i

  @everyone_sacrifices_land ~r/each (player|opponent) sacrifices (a|an|\w+) (?:[a-z]+ )?lands?\b/i

  # "Take an extra turn after this one" and its variants. Excludes "target
  # player takes an extra turn" given to an opponent as a drawback? No — the
  # brackets care that the effect is in the deck at all.
  @extra_turn ~r/takes? an extra turn/i

  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    body = card.oracle_text || ""

    land_denial(body) ++ extra_turn(body)
  end

  defp land_denial(body) do
    cond do
      body =~ @destroys_all_lands ->
        [RoleMatch.new(:mass_land_denial, :high, "destrói todos os terrenos")]

      body =~ @everyone_sacrifices_land ->
        [RoleMatch.new(:mass_land_denial, :high, "cada jogador sacrifica terreno")]

      true ->
        []
    end
  end

  defp extra_turn(body) do
    if body =~ @extra_turn,
      do: [RoleMatch.new(:extra_turn, :high, "concede turno extra")],
      else: []
  end
end
