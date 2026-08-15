defmodule Deckex.Cards.Roles.Table do
  @moduledoc """
  The six roles that describe what a deck is like to sit across from.

  These are not power measurements. A taxing enchantment and a theft effect can
  both sit in a weak deck; what they have in common is that the table *notices*
  them, and the community's own salt survey is made almost entirely of these
  categories — lockout and time theft, rather than attrition. The engine could
  see none of them, which is why its idea of an unpleasant deck stopped at
  counterspells and land destruction.

  Every rule below carries the exclusion that makes it honest, because the
  near-miss is always a card that would be wrong to flag:

  - **Taxation** is pay-or-I-profit, in its two printed shapes: "unless that
    player pays" (Rhystic Study) and "may pay … if they don't, you …"
    (Smothering Tithe). A card that merely costs more to cast is not taxing
    anyone.
  - **Theft** needs an opponent's card changing hands. "Under your control" on
    its own is how every token in Magic is created, so the rule requires an
    opponent in the same sentence, or the explicit "gain control".
  - **Hoser** removes a category of play — "can't cast", "lose all abilities" —
    rather than a resource. That is what separates it from stax.
  - **Forced sacrifice** is an edict. "Destroy" is not sacrifice: regeneration,
    indestructible and the choice itself all behave differently.
  - **Free spell** means *this* spell has the alternative cost. "Cast **it**
    without paying its mana cost" is cascade and plot — value engines that
    hand you other cards, not the free interaction that makes an empty board
    feel unsafe.
  - **Chaos** is *explicit* randomness: coins, dice, "at random". A deck-wide
    reset like Warp World reads as chaos to a player and matches nothing here —
    detecting that from text would cost more precision than it buys, and the AI
    residue pass already sees what the rules cannot.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch

  @taxation ~r/unless (that|its|the) (player|controller|opponent) pays|may pay \{[^}]+\}\.?\s*If (the|that) player doesn't/i

  @theft ~r/gain control of|opponents?[^.]*under your control|you may cast .*? from (any|an opponent's)/i

  @hoser ~r/(players?|opponents?) can't (cast|play|activate|search)|(all|each) creatures? lose all abilities/i

  @forced_sacrifice ~r/each (opponent|other player) sacrifices/i

  @free_spell ~r/rather than pay this spell's mana cost|cast this spell without paying its mana cost/i

  @chaos ~r/flip a coin|roll a (six-sided )?di[ec]|chosen at random/i

  # Taxation only counts on a permanent. A soft counter reads identically —
  # "unless its controller pays {1}" — but taxes one spell once and is already
  # a counterspell; what a table resents is the enchantment that charges a toll
  # every turn for the rest of the game.
  @ongoing_only [:taxation]

  @rules [
    {:taxation, @taxation, "cobra pedágio dos oponentes"},
    {:theft, @theft, "toma o que é do outro"},
    {:hoser, @hoser, "desliga uma categoria inteira de jogada"},
    {:forced_sacrifice, @forced_sacrifice, "força sacrifício alheio"},
    {:free_spell, @free_spell, "custo alternativo sem mana"},
    {:chaos, @chaos, "aleatoriedade na mesa"}
  ]

  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    body = card.oracle_text || ""

    for {kind, pattern, evidence} <- @rules,
        body =~ pattern,
        kind not in @ongoing_only or permanent?(card) do
      RoleMatch.new(kind, :high, evidence)
    end
  end

  defp permanent?(%Card{type_line: type_line}) do
    front = type_line |> to_string() |> String.split("//") |> hd()

    not String.contains?(front, "Instant") and not String.contains?(front, "Sorcery")
  end
end
