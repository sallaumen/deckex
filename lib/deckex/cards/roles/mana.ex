defmodule Deckex.Cards.Roles.Mana do
  @moduledoc """
  Rules for the roles that touch mana: `:ramp`, `:ritual`, `:cost_reduction` and
  `:fixing`.

  Four distinctions here were learned from real decklists and are easy to get
  wrong:

  1. **A fetchland is not ramp.** Its text matches "search your library for a
     ... Mountain ...", exactly like Nature's Lore, but it sacrifices itself —
     net zero mana. Lands are excluded from `:ramp`, and land-fetching lands are
     `:fixing`.
  2. **A ritual is not ramp.** `Desperate Ritual` adds three mana once. It does
     not let you cast a six-drop a turn earlier from an empty board, and
     counting it as ramp overstates a deck's acceleration.
  3. **Self-discount is not cost reduction.** `Blasphemous Act` says "This spell
     costs {1} less"; that helps no other card. The rule matches discounts on
     *your spells*, not on the card itself.
  4. **`produced_mana` alone is insufficient.** `Cultivate` produces no mana by
     that field and is still one of the format's most-played ramp spells; only
     the oracle text reveals it.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch
  alias Deckex.Cards.Roles.Reading

  # "Search your library for ... land ... onto the battlefield" — the Cultivate
  # shape. `[^.]*` keeps the match inside one sentence so an unrelated later
  # clause cannot satisfy it, and the gap after "library" absorbs "and/or
  # graveyard".
  @fetches_land ~r/search your library[^.]{0,30}?\bfor\b[^.]*\bland\b[^.]*onto the battlefield/i

  # A land type named directly, as fetchlands and Nature's Lore do.
  @fetches_land_type ~r/search your library[^.]{0,30}?\bfor\b[^.]*\b(plains|island|swamp|mountain|forest)\b/i

  # "... spells you cast cost {1} less" — a discount on OTHER cards. The gap
  # absorbs a condition ("Each spell you cast that's red or green costs {1}
  # less"). Deliberately does not match "This spell costs {1} less", which
  # discounts nothing but itself.
  @discounts_your_spells ~r/spells?\s+you\s+cast[^.]{0,40}?costs?\s+\{[^}]+\}\s+less/i

  @treasure ~r/create[sd]?\s+.*\btreasure\b/i

  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    Enum.flat_map([&ramp/1, &ritual/1, &cost_reduction/1, &fixing/1], & &1.(card))
  end

  # --- ramp -----------------------------------------------------------------

  # Order matters. The treasure check comes BEFORE `produces_mana?` because
  # Scryfall populates `produced_mana` for treasure makers (Storm-Kiln Artist
  # lists all five colours), and a creature that makes a token that taps for
  # mana is a weaker signal than one that taps for mana itself.
  defp ramp(card) do
    cond do
      land?(card) -> []
      instant_or_sorcery?(card) and produces_mana?(card) -> []
      treasure_maker?(card) -> [RoleMatch.new(:ramp, :medium, "cria Treasure")]
      produces_mana?(card) -> [tap_for_mana(card)]
      fetches_land?(card) -> [RoleMatch.new(:ramp, :high, "busca terreno para o campo")]
      true -> []
    end
  end

  defp tap_for_mana(card) do
    RoleMatch.new(:ramp, :high, "permanente que produz #{Enum.join(card.produced_mana, "")}")
  end

  # --- ritual ---------------------------------------------------------------

  defp ritual(card) do
    if instant_or_sorcery?(card) and produces_mana?(card) do
      [RoleMatch.new(:ritual, :high, "mágica que adiciona mana de uma vez")]
    else
      []
    end
  end

  # --- cost reduction -------------------------------------------------------

  defp cost_reduction(card) do
    if text(card) =~ @discounts_your_spells do
      [RoleMatch.new(:cost_reduction, :high, "reduz o custo das suas mágicas")]
    else
      []
    end
  end

  # --- fixing ---------------------------------------------------------------

  defp fixing(card) do
    cond do
      length(card.produced_mana) >= 2 ->
        [RoleMatch.new(:fixing, :high, "produz #{length(card.produced_mana)} cores")]

      land?(card) and fetches_land?(card) ->
        [RoleMatch.new(:fixing, :high, "terreno que busca terreno")]

      fetches_land?(card) ->
        [RoleMatch.new(:fixing, :medium, "busca terreno específico")]

      true ->
        []
    end
  end

  # --- predicates -----------------------------------------------------------

  defp text(card), do: Reading.body(card)

  defp front_type(card), do: card.type_line |> String.split("//") |> hd()

  defp land?(card), do: String.contains?(front_type(card), "Land")

  defp instant_or_sorcery?(card) do
    type = front_type(card)

    String.contains?(type, "Instant") or String.contains?(type, "Sorcery")
  end

  defp produces_mana?(card), do: card.produced_mana != []

  defp treasure_maker?(card), do: text(card) =~ @treasure

  defp fetches_land?(card) do
    body = text(card)

    body =~ @fetches_land or body =~ @fetches_land_type
  end
end
