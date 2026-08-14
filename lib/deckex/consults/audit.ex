defmodule Deckex.Consults.Audit do
  @moduledoc """
  The engine's verdict on an AI answer.

  Two verifications, both arithmetic. **Legality:** every add is checked
  against the card's actual data — colour identity, the singleton rule,
  Commander legality — and every cut against the list it claims to cut from.
  **Impact:** the problem-free changes are applied to the snapshot in memory
  and the findings diffed, so "this fixes your mana" stops being a claim and
  becomes a measured before→after.

  Suggestions with problems are excluded from the simulation: an illegal add
  must not be allowed to look like it fixes anything.
  """

  alias Deckex.Analysis
  alias Deckex.Analysis.Baselines
  alias Deckex.Analysis.Bracket
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding
  alias Deckex.Analysis.ReportDiff
  alias Deckex.Analysis.Simulation
  alias Deckex.Cards.Card
  alias Deckex.Cards.Name
  alias Deckex.Consults.Suggestion
  alias Deckex.Money

  @type problem_key :: {:cut | :add, String.t()}
  @type t :: %__MODULE__{
          problems: %{problem_key() => [String.t()]},
          resolved: [Finding.t()],
          remaining: [Finding.t()],
          introduced: [Finding.t()]
        }

  defstruct problems: %{}, resolved: [], remaining: [], introduced: []

  @doc """
  Audits `suggestions` against `snapshot`. `roles` maps card ids to the roles
  the classifier stored — the added entries need them, or the simulated report
  would count every add as a blank card.
  """
  @spec run(
          DeckSnapshot.t(),
          [Suggestion.t()],
          %{String.t() => list()},
          Baselines.t(),
          %{card: pos_integer() | nil, land: pos_integer() | nil},
          keyword()
        ) :: t()
  def run(
        %DeckSnapshot{} = snapshot,
        suggestions,
        roles,
        %Baselines{} = baselines,
        ceilings \\ %{card: nil, land: nil},
        opts \\ []
      ) do
    in_main = MapSet.new(snapshot.main, &Name.normalize(&1.card.name))
    pipeline = opts |> pipeline_opts() |> Map.put(:roles_for_adds, roles)

    problems =
      suggestions
      |> Enum.map(&{key(&1), problems(&1, snapshot, in_main, ceilings, pipeline)})
      |> Enum.reject(fn {_key, list} -> list == [] end)
      |> Map.new()

    changes =
      suggestions
      |> Enum.filter(&(&1.resolved? and not Map.has_key?(problems, key(&1))))
      |> Enum.map(&change(&1, roles))

    before_report = Analysis.report(snapshot, baselines)
    after_report = Analysis.report(Simulation.apply_changes(snapshot, changes), baselines)
    diff = ReportDiff.diff(before_report, after_report)

    %__MODULE__{
      problems: problems,
      resolved: diff.resolved,
      remaining: diff.remaining,
      introduced: diff.introduced
    }
  end

  defp key(%Suggestion{action: action, name: name}), do: {action, name}

  # The three rules that only exist inside an optimization run, where nobody
  # is clicking per-suggestion and the engine is the only gate.
  defp pipeline_opts(opts) do
    %{
      flips:
        opts |> Keyword.get(:history, []) |> Enum.frequencies_by(&Name.normalize(&1["card"])),
      keep: opts |> Keyword.get(:keep, []) |> MapSet.new(&Name.normalize/1),
      bracket_max: Keyword.get(opts, :bracket_max)
    }
  end

  # Ping-pong is chained critics' known failure mode, and it is countable.
  # One appearance in the history is a change; a second is the revert — the
  # legitimate disagreement. A third touch is churn, and the engine ends it.
  defp flip_flop_problem(%{flips: flips}, name) do
    if Map.get(flips, Name.normalize(name), 0) >= 2 do
      "já entrou e saiu nesta otimização — o vaivém para aqui"
    end
  end

  defp keep_problem(%Suggestion{action: :cut, name: name}, %{keep: keep}) do
    if MapSet.member?(keep, Name.normalize(name)) do
      "está na lista de proteção desta otimização"
    end
  end

  # Inside a pipeline the bracket note becomes a hard rule: an add that moves
  # the sandbox past the contract's bracket is refused, not annotated.
  defp contract_bracket_problem(_card, _entry_roles, %{bracket_max: nil}, _snapshot), do: nil

  defp contract_bracket_problem(card, entry_roles, %{bracket_max: max}, snapshot) when max <= 3 do
    changers = Enum.count(snapshot.main ++ snapshot.commanders, & &1.card.game_changer)

    cond do
      card.game_changer and changers >= 3 ->
        "seria o 4º Game Changer — o contrato limita ao Bracket #{max}"

      :mass_land_denial in entry_roles or :extra_turn in entry_roles ->
        "leva o deck ao Bracket 4, acima do contrato"

      true ->
        nil
    end
  end

  defp contract_bracket_problem(_card, _roles, _pipeline, _snapshot), do: nil

  # An unresolved suggestion has no card data to check; the table already
  # marks it and the simulation cannot use it.
  defp problems(%Suggestion{resolved?: false}, _snapshot, _in_main, _ceilings, _pipe), do: []

  defp problems(%Suggestion{action: :cut} = suggestion, _snapshot, in_main, _ceilings, pipeline) do
    presence =
      if MapSet.member?(in_main, Name.normalize(suggestion.name)),
        do: nil,
        else: "não está na lista principal"

    Enum.reject(
      [
        presence,
        keep_problem(suggestion, pipeline),
        flip_flop_problem(pipeline, suggestion.name)
      ],
      &is_nil/1
    )
  end

  defp problems(
         %Suggestion{action: :add, card: card} = suggestion,
         snapshot,
         in_main,
         ceilings,
         pipeline
       ) do
    entry_roles = MapSet.new(pipeline.roles_for_adds |> Map.get(card && card.id, []))

    Enum.reject(
      [
        identity_problem(card, snapshot.color_identity),
        singleton_problem(card, suggestion, in_main),
        legality_problem(card),
        ceiling_problem(card, suggestion.price_usd, ceilings),
        bracket_problem(card, snapshot),
        contract_bracket_problem(card, entry_roles, pipeline, snapshot),
        flip_flop_problem(pipeline, suggestion.name)
      ],
      &is_nil/1
    )
  end

  # The ceiling the owner set, checked against the price Scryfall reports —
  # not against the price the model believes. A land gets the lower ceiling
  # because an expensive land is the easiest way to spend a lot and win
  # nothing. An unpriced card passes: refusing a card because we do not know
  # what it costs would be inventing a fact.
  defp ceiling_problem(_card, nil, _ceilings), do: nil

  defp ceiling_problem(card, price_usd, ceilings) do
    ceiling = if Card.land?(card), do: ceilings[:land], else: ceilings[:card]
    brl = Money.to_brl(price_usd)

    if ceiling && brl && Decimal.gt?(brl, Decimal.new(ceiling)) do
      "R$ #{Decimal.round(brl, 2)} passa do teto de R$ #{ceiling}"
    end
  end

  defp identity_problem(card, deck_identity) do
    outside = card.color_identity -- deck_identity

    if outside == [] do
      nil
    else
      "fora da identidade de cor (#{Enum.join(outside, "")}) — ilegal"
    end
  end

  defp singleton_problem(card, suggestion, in_main) do
    cond do
      Card.basic_land?(card) or Card.any_number_allowed?(card) ->
        nil

      MapSet.member?(in_main, Name.normalize(suggestion.name)) ->
        "já está no deck — Commander é singleton"

      true ->
        nil
    end
  end

  defp legality_problem(%Card{commander_legal: false}), do: "não é legal em Commander"
  defp legality_problem(_card), do: nil

  # A Game Changer is legal everywhere — what it changes is which table the
  # deck belongs at. A deck sitting on three of them is one suggestion away
  # from leaving bracket 3, and nothing else in the app would have said so:
  # every model consulted about the reference deck suggested Cyclonic Rift,
  # which is exactly that fourth card.
  defp bracket_problem(%Card{game_changer: true}, snapshot) do
    bracket = Bracket.floor(snapshot)

    case Bracket.game_changer_headroom(bracket) do
      nil -> "é Game Changer (o deck já está no piso do Bracket 4)"
      0 -> "é Game Changer — seria o 4º e tira o deck do Bracket 3"
      room -> "é Game Changer — sobra espaço para #{room} no Bracket 3"
    end
  end

  defp bracket_problem(_card, _snapshot), do: nil

  defp change(%Suggestion{action: :cut, name: name}, _roles), do: {:cut, Name.normalize(name)}

  defp change(%Suggestion{action: :add, card: card}, roles) do
    {:add, CardEntry.new(card, 1, Map.get(roles, card.id, []))}
  end
end
