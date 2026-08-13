defmodule Deckex.Cards.Roles.Value do
  @moduledoc """
  Rules for the roles that generate advantage rather than answer a threat:
  `:draw`, `:tutor`, `:recursion`, `:graveyard_hate` and `:stax`.

  Two exclusions matter here:

  - The tutor rule ignores library searches that name a land — those are ramp or
    fixing and belong to `Deckex.Cards.Roles.Mana`. Counting Cultivate and eight
    fetchlands as tutors would make almost any deck look far more consistent
    than it is.
  - The draw rule ignores an *opponent* drawing. `Smothering Tithe` triggers on
    "whenever an opponent draws a card" and gives you a Treasure, not a card.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch

  # "you draw" / "you may draw" / an imperative "Draw two cards". Deliberately
  # NOT a bare "draws a card".
  @draw ~r/(?:you may draw|you draw|^draw)\s+(?:a|\w+)\s+cards?/im

  # The gap after "library" absorbs another zone: Finale of Devastation reads
  # "Search your library and/or graveyard for a creature card".
  @search ~r/search your library[^.]{0,30}?\bfor\b([^.]*)/i
  @land_search ~r/\b(land|plains|island|swamp|mountain|forest)\b/i

  @recursion ~r/return .* from your graveyard|\bflashback\b|cast .* from your graveyard/i

  @graveyard_hate ~r/exile .*(target player's|each opponent's|all) graveyard|exile .* from a graveyard/i

  @stax ~r/unless that player pays|unless its controller pays|can't (be cast|attack|untap)|costs? \{[^}]+\} more/i

  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    body = card.oracle_text || ""

    draw(body) ++ tutor(body) ++ recursion(body) ++ graveyard_hate(body) ++ stax(body)
  end

  defp draw(body) do
    if body =~ @draw, do: [RoleMatch.new(:draw, :high, "compra carta")], else: []
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
    if body =~ @graveyard_hate,
      do: [RoleMatch.new(:graveyard_hate, :high, "exila cemitério")],
      else: []
  end

  defp stax(body) do
    if body =~ @stax do
      [RoleMatch.new(:stax, :medium, "taxa ou restringe o oponente")]
    else
      []
    end
  end
end
