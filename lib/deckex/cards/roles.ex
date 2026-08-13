defmodule Deckex.Cards.Roles do
  @moduledoc """
  The rule engine: a pure function from a card to the roles it plays.

  Rules resolve the obvious majority for free and instantly. What they cannot
  place is *residue*, handed to the AI by `Deckex.Cards.RoleAI` and cached on
  the card forever — so the same card is never paid for twice, across any deck.

  `Sol Ring` is the canonical rule hit: one field, zero cost. `Young Pyromancer`
  is the canonical residue: it produces no mana, answers nothing and draws
  nothing, so no regex finds it. The split between them is the whole design.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch
  alias Deckex.Cards.Roles.Interaction
  alias Deckex.Cards.Roles.Mana
  alias Deckex.Cards.Roles.Value

  @confidence_rank %{high: 3, medium: 2, low: 1}

  @doc """
  Every role the rules can assign to `card`, at most one match per kind.
  """
  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    [Mana, Interaction, Value]
    |> Enum.flat_map(& &1.classify(card))
    |> best_per_kind()
  end

  @doc """
  Whether the rules failed to place this card, meaning it must go to the AI.

  A card with only low-confidence matches counts as residue: a guess is not an
  answer, and the AI pass is cheap because the result is cached globally.
  """
  @spec residue?(Card.t()) :: boolean()
  def residue?(%Card{} = card) do
    case classify(card) do
      [] -> true
      matches -> Enum.all?(matches, &(&1.confidence == :low))
    end
  end

  defp best_per_kind(matches) do
    matches
    |> Enum.group_by(& &1.kind)
    |> Enum.map(fn {_kind, group} -> Enum.max_by(group, &@confidence_rank[&1.confidence]) end)
    |> Enum.sort_by(& &1.kind)
  end
end
