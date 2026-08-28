defmodule Deckex.Cards.Roles.Board do
  @moduledoc """
  Rules for the roles that put a board on the table: `:token_engine` and
  `:anthem`.

  A go-wide deck is built on exactly two shapes, and until these rules existed
  the engine could see neither. The owner said it before the code did: the
  creatures that *make* creatures matter more than most creatures — a deck
  whose plan is "a troop of 1/1s with prowess and haste" is carried by its
  generators and its anthems, and an engine that reads them as blank cards
  tells every stage to cut the deck's spine.

  The distinctions that keep the rules honest:

  - **An engine repeats; a burst does not.** `:token_engine` is a permanent
    whose trigger ("whenever", "at the beginning of") or activated ability
    keeps producing — Young Pyromancer makes an Elemental *per spell*. A
    sorcery that makes three Spirits made three bodies once, and an
    enter-the-battlefield trigger fires once per casting: neither is an
    engine, and neither defends next turn. Bursts are the AI residue's
    judgement call, not a rule's.
  - **A creature token, not a token.** Treasure, Clue, Food and Blood all say
    "create" — and Treasure is already `:ramp`. The rule requires the words
    "creature token".
  - **An anthem lifts the team.** "Creatures you control get +X/+X" or
    "have/gain <ability>" — including the "creature tokens you control"
    phrasing go-wide payoffs use. On a permanent it is the deck's engine
    (`:high`); on an instant or sorcery it is the finisher's pump (`:medium`),
    and both are the payoff half of the plan the generators start.
  """

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch
  alias Deckex.Cards.Roles.Reading

  @creates_creatures ~r/creates?\b[^.]{0,120}?\bcreature tokens?/i

  # The clauses that make production repeatable: a trigger that keeps firing,
  # or an activated ability (its cost ends in ":"). "When this creature
  # enters" deliberately fails both — it fires once per casting.
  @repeats ~r/\bwhenever\b|\bat the beginning of\b|:\s*[^.]*creates?\b/i

  @anthem_pump ~r/creatures?(?: tokens?)? you control get \+/i
  @anthem_grant ~r/creatures?(?: tokens?)? you control (?:have|gain)\b/i

  @spec classify(Card.t()) :: [RoleMatch.t()]
  def classify(%Card{} = card) do
    body = Reading.body(card)

    token_engine(card, body) ++ anthem(card, body)
  end

  defp token_engine(card, body) do
    if permanent?(card) and repeatable_creation?(body) do
      [RoleMatch.new(:token_engine, :high, "gera criaturas repetidamente")]
    else
      []
    end
  end

  # The creating sentence itself must be the repeatable one — a card that
  # says "Whenever X, draw" in one sentence and "create a token" in an ETB
  # clause is not an engine.
  defp repeatable_creation?(body) do
    body
    |> String.split(["\n", ". "])
    |> Enum.any?(&(&1 =~ @creates_creatures and &1 =~ @repeats))
  end

  defp anthem(card, body) do
    cond do
      not (body =~ @anthem_pump or body =~ @anthem_grant) ->
        []

      permanent?(card) ->
        [RoleMatch.new(:anthem, :high, "levanta o time inteiro")]

      true ->
        [RoleMatch.new(:anthem, :medium, "pump coletivo de uma vez")]
    end
  end

  defp permanent?(%Card{type_line: type_line}) do
    front = type_line |> to_string() |> String.split("//") |> hd()

    not String.contains?(front, "Instant") and not String.contains?(front, "Sorcery")
  end
end
