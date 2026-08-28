defmodule Deckex.Cards.Roles.Value do
  @moduledoc """
  Rules for the roles that generate advantage rather than answer a threat:
  `:draw`, `:tutor`, `:recursion`, `:graveyard_hate`, `:stax` and `:wincon`.

  The exclusions are the rules' honesty:

  - The tutor rule ignores library searches that name a land — those are ramp or
    fixing and belong to `Deckex.Cards.Roles.Mana`. Counting Cultivate and eight
    fetchlands as tutors would make almost any deck look far more consistent
    than it is.
  - The draw rule ignores an *opponent* drawing. `Smothering Tithe` triggers on
    "whenever an opponent draws a card" and gives you a Treasure, not a card.
    The exclusion is per clause, not per card: Consecrated Sphinx mentions the
    opponent's draw *and* yours, and losing the second because of the first
    would cost a deck its best draw engine.
  - Card advantage that never says "draw" still counts. Fact or Fiction puts a
    pile **into your hand**; Light Up the Stage exiles from your library and
    lets you **play** the cards. Measured on a real spellslinger deck: the
    engine read 10 draw where the deck held 13, and every stage briefed from
    that number was told to fix a problem the deck did not have.
  - "Into your hand" inside a **search** sentence is a tutor, not draw —
    Demonic Tutor already counts once.
  - The wincon rule matches only sentences that name the act: "you win the
    game", "each opponent loses the game". Everything subtler is judgement,
    and judgement is the AI residue pass's job.
  - An amplifier makes the deck's own triggers and spells happen twice —
    "triggers an additional time" (Harmonic Prodigy, Veyran) or copying a
    spell (Reiterate, Kitsa). The trigger doublers were the largest residue
    class left in the reference decks, and every one is the card its deck is
    built around. "Cast **or copy**" as a trigger condition copies nothing,
    and the rule's `target|that` guard keeps it out.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch
  alias Deckex.Cards.Roles.Reading

  # Any draw clause, wherever it sits in the sentence — "Whenever you cast or
  # copy an instant or sorcery spell, draw a card" is the format's premier
  # card-advantage shape and a line-start anchor missed it. Whose draw it is
  # gets decided per sentence, below.
  @draw ~r/\bdraws?\s+(?:(?:a|an|one|two|three|four|five|six|seven|x|that many|\w+)\s+)?cards?\b/i

  # An opponent's draw, WITH its draw words, so stripping the phrase leaves
  # the sentence's other draws intact — Consecrated Sphinx keeps yours. The
  # subject must sit right next to the verb: a proximity window ate Rhystic
  # Study, whose "an opponent casts a spell" stood 23 characters before "you
  # may draw", and the premier draw engine of the format read as zero.
  @opponent_draw ~r/\b(?:an opponent|each opponent|target opponent|that player|its controller|each other player|defending player)\s+draws?\b(?:\s+\w+)?\s+cards?/i

  # "Put one pile into your hand" — card advantage that never says draw.
  @into_hand ~r/\bputs?\b[^.]{0,80}\binto your hand\b/i

  # Impulse draw: exile off the top of YOUR library, permission to play it.
  @impulse_exile ~r/exiles? the top[^.]{0,60}of your library/i
  @impulse_play ~r/may (?:play|cast)/i

  # The sentences that name the act. "You can't win the game" never contains
  # this substring, so no lookbehind is needed.
  @wins ~r/you win the game|each opponent loses the game/i

  # Twice the triggers, or another copy of the spell. `target|that` is the
  # guard: "whenever you cast or copy an instant" is a trigger CONDITION, and
  # matching it would hand the role to every magecraft payoff in the format.
  @amplifies ~r/triggers? an additional time|cop(?:y|ies) (?:target|that) (?:instant|sorcery|spell)/i

  # The gap after "library" absorbs another zone: Finale of Devastation reads
  # "Search your library and/or graveyard for a creature card".
  @search ~r/search your library[^.]{0,30}?\bfor\b([^.]*)/i
  @land_search ~r/\b(land|plains|island|swamp|mountain|forest)\b/i

  # The graveyard-cast keywords by name, because their mechanics live in
  # reminder text the rules no longer read: Underworld Breach grants escape in
  # its own words and explains it in parentheses, and stripping the reminder
  # without knowing the keyword cost the format's premier recursion engine its
  # role.
  @recursion ~r/return .* from your graveyard|cast .* from your graveyard|\b(flashback|escape[ —–-]?cost|escape\\s*[—–-]|disturb|unearth|embalm|eternalize|jump-start|retrace|encore|harmonize)\b/i

  @graveyard_hate ~r/exile .*(target player's|each opponent's|all) graveyard|exile .* from a graveyard/i

  # Hate that files instead of exiling: Endurance puts a graveyard on the
  # bottom of its owner's library, and no "exile" pattern will ever see it.
  # The possessives keep self-mill and self-shuffle (your graveyard) out —
  # milling yourself is a build-around, and only aiming at someone is hate.
  @graveyard_filed ~r/puts?\b[^.]{0,50}\bfrom (?:their|a|target player's|each opponent's) graveyards?\b[^.]{0,50}librar/i

  @stax ~r/unless that player pays|unless its controller pays|can't (be cast|attack|untap)|costs? \{[^}]+\} more/i

  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    body = Reading.body(card)

    draw(body) ++
      tutor(body) ++
      recursion(body) ++ graveyard_hate(body) ++ stax(body) ++ wincon(body) ++ amplifier(body)
  end

  defp draw(body) do
    cond do
      self_draw?(body) ->
        [RoleMatch.new(:draw, :high, "compra carta")]

      hand_filler?(body) ->
        [RoleMatch.new(:draw, :medium, "põe carta na mão sem dizer \"draw\"")]

      impulse?(body) ->
        [RoleMatch.new(:draw, :medium, "exila do topo e deixa jogar")]

      true ->
        []
    end
  end

  # Per sentence: strip the opponent's draw clause first, then ask whether a
  # draw is still there. One card can hold both — Consecrated Sphinx triggers
  # on an opponent's draw and answers with yours.
  defp self_draw?(body) do
    body
    |> sentences()
    |> Enum.any?(fn sentence -> Regex.replace(@opponent_draw, sentence, "") =~ @draw end)
  end

  # "Into your hand" in a search sentence would be the tutor counting twice.
  defp hand_filler?(body) do
    body
    |> sentences()
    |> Enum.any?(fn sentence ->
      sentence =~ @into_hand and not (sentence =~ ~r/search your librar/i)
    end)
  end

  # The permission usually lives in the sentence after the exile, so this one
  # reads the whole body.
  defp impulse?(body), do: body =~ @impulse_exile and body =~ @impulse_play

  defp sentences(body), do: String.split(body, ~r/[.\n]/)

  defp wincon(body) do
    if body =~ @wins, do: [RoleMatch.new(:wincon, :high, "nomeia a vitória no texto")], else: []
  end

  defp amplifier(body) do
    if body =~ @amplifies,
      do: [RoleMatch.new(:amplifier, :high, "dobra gatilhos ou copia mágicas")],
      else: []
  end

  # A search only counts as a tutor when what it looks for is not a land.
  defp tutor(body) do
    case Regex.run(@search, body, capture: :all_but_first) do
      [target] ->
        if target =~ @land_search,
          do: [],
          else: [RoleMatch.new(:tutor, :high, "busca carta na biblioteca")]

      _no_search ->
        []
    end
  end

  defp recursion(body) do
    if body =~ @recursion do
      [RoleMatch.new(:recursion, :medium, "reusa carta do cemitério")]
    else
      []
    end
  end

  defp graveyard_hate(body) do
    cond do
      body =~ @graveyard_hate ->
        [RoleMatch.new(:graveyard_hate, :high, "exila cemitério")]

      body =~ @graveyard_filed ->
        [RoleMatch.new(:graveyard_hate, :high, "arquiva cemitério na biblioteca")]

      true ->
        []
    end
  end

  defp stax(body) do
    if body =~ @stax do
      [RoleMatch.new(:stax, :medium, "taxa ou restringe o oponente")]
    else
      []
    end
  end
end
