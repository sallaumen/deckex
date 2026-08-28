defmodule Deckex.Cards.Roles.Interaction do
  @moduledoc """
  Rules for the roles that answer an opponent: `:counter`, `:spot_removal`,
  `:board_wipe` and `:protection`.

  `:counter` and `:spot_removal` are deliberately separate and must never be
  summed into one "interaction" number. A counterspell is a dead card once the
  threat has resolved; against an aggressive deck only the answers that address
  a permanent already on the battlefield count.

  Removal is every shape the colour pie prints it in, not just the two verbs.
  Measured on a real Temur deck: Chaos Warp — shuffle-into-library — carried
  no role at all, because blue and red don't say "destroy". Bounce, tuck,
  -X/-X, fight and the edict are all removal to the player sitting across
  from them, and each carries the exclusion that keeps it honest:

  - Bouncing a permanent **you control** is protection, not removal.
  - "Target creature **card**" is a graveyard's object, not the battlefield's.
  - The wipe rules exclude "each creature **you control**" — a pump clause on
    a removal spell (`Overwhelming Victory`) otherwise reads as a board wipe.
  - A spell put on top or bottom of its owner's library never resolved: that
    is a counter in effect, whatever the verb.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch
  alias Deckex.Cards.Roles.Reading

  @counter ~r/counter target/i

  # A spell that never resolves is countered, whatever the verb: Subtlety puts
  # it on top or bottom of the library, Hullbreaker Horror hands it back. The
  # window crosses one sentence boundary because Subtlety's verb lands in the
  # sentence after its target.
  @counter_denies ~r/returns? (?:up to \w+ )?target spell|target [^.]{0,40}spell\b.{0,120}?(top|bottom) of (their|its owner's) librar/is

  @destroys_all ~r/(destroy|exile) all\b/i

  # Mass damage, but not the "each creature you control" pump clause.
  @damages_all ~r/damage to each creature(?! you control)/i

  @sacrifice_all ~r/each (player|opponent) sacrifices/i

  # Mass bounce and mass -X/-X close a board exactly like destruction does —
  # Perplexing Test and Toxic Deluge are sweepers in any player's hands.
  @bounce_all ~r/returns? (all|each)\b[^.]*\bto their owners' hands?/i
  @shrink_all ~r/(all|each) creatures?(?! you control)[^.]{0,30}gets? -/i

  @spot ~r/(destroy|exile) target|damage to target (creature|permanent|planeswalker)|damage to any target/i

  # The other shapes of "this permanent is gone": bounce (not of your own),
  # tuck (Chaos Warp, Oust — but never "target creature card", which lives in
  # a graveyard), -X/-X, the fight and the bite, and the edict.
  @spot_bounce ~r/returns? (?:up to \w+ )?target (?:[a-z]+ )*?(permanent|creature|artifact|enchantment|planeswalker)\b(?![^.]*you control)[^.]{0,40}\bto (its|their) owner/i
  @spot_tuck ~r/shuffles? (it|target[^.]{0,30}) into (its owner's|their) librar|puts? target (?:[a-z]+ )*?(permanent|creature|artifact|enchantment|planeswalker)(?! card)\b[^.]{0,60}librar/i
  @spot_shrink ~r/target creature gets? -/i
  @spot_fight ~r/fights? (up to \w+ )?target|deals damage equal to its power to target/i
  @spot_edict ~r/(target (player|opponent)|each opponent) sacrifices? [^.]{0,30}creature/i

  @protection ~r/\b(hexproof|indestructible|shroud|protection from|ward)\b/i

  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    body = Reading.body(card)

    counter(body) ++ mass_or_spot(body) ++ protection(body)
  end

  defp counter(body) do
    cond do
      body =~ @counter ->
        [RoleMatch.new(:counter, :high, "contra-magia (\"counter target\")")]

      body =~ @counter_denies ->
        [RoleMatch.new(:counter, :high, "nega a mágica sem dizer \"counter\"")]

      true ->
        []
    end
  end

  # A card is a wipe or spot removal, never both: the wipe clause on a sweeper
  # would otherwise also trip the spot pattern via a secondary mode.
  defp mass_or_spot(body) do
    cond do
      wipe?(body) -> [RoleMatch.new(:board_wipe, :high, "atinge todas as criaturas")]
      spot?(body) -> [RoleMatch.new(:spot_removal, :high, "remove um alvo único")]
      true -> []
    end
  end

  defp wipe?(body) do
    body =~ @destroys_all or body =~ @damages_all or body =~ @sacrifice_all or
      body =~ @bounce_all or body =~ @shrink_all
  end

  defp spot?(body) do
    body =~ @spot or body =~ @spot_bounce or body =~ @spot_tuck or body =~ @spot_shrink or
      body =~ @spot_fight or body =~ @spot_edict
  end

  defp protection(body) do
    if body =~ @protection do
      [RoleMatch.new(:protection, :medium, "concede proteção (hexproof/indestructible/ward)")]
    else
      []
    end
  end
end
