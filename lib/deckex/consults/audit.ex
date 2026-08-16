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
  alias Deckex.Budget
  alias Deckex.Cards.Card
  alias Deckex.Cards.Name
  alias Deckex.Consults.Suggestion
  alias Deckex.Money
  alias Deckex.Optimizations.Balance

  @type problem_key :: {:cut | :add, String.t()}
  @type t :: %__MODULE__{
          problems: %{problem_key() => [String.t()]},
          notes: %{problem_key() => [String.t()]},
          resolved: [Finding.t()],
          remaining: [Finding.t()],
          introduced: [Finding.t()]
        }

  # `notes` is deliberately a separate field from `problems`, not a severity
  # inside it. A problem rejects the suggestion and pulls it out of the
  # simulation; a note is the engine saying "this one spends your second
  # exception" and changing nothing. The Game Changer headroom already taught
  # this lesson the expensive way, by masquerading as a problem and silently
  # rejecting every legal add.
  defstruct problems: %{}, notes: %{}, resolved: [], remaining: [], introduced: []

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
    policy = Keyword.get(opts, :budget_policy) || Budget.policy()

    context = %{
      snapshot: snapshot,
      in_main: in_main,
      ceilings: ceilings,
      pipeline: pipeline,
      policy: policy,
      card_count: Keyword.get(opts, :card_count),
      balance_mode: Keyword.get(opts, :balance_mode, :stage)
    }

    # A fold, not a map: the quota is a property of the whole answer. Three
    # separate suggestions each asking "is there room for one more exception?"
    # would all be told yes, and applying the three would leave the deck with
    # three of the two the owner allows. Cuts come first in the list, so a cut
    # that frees a slot is already counted when the adds are judged.
    {found, notes, _spent} =
      Enum.reduce(
        suggestions,
        {%{}, %{}, Budget.occupancy(snapshot.main ++ snapshot.commanders, policy)},
        &judge(&1, &2, context)
      )

    problems = Map.merge(found, balance_problems(suggestions, found, context))

    changes =
      suggestions
      |> Enum.filter(&(&1.resolved? and not Map.has_key?(problems, key(&1))))
      |> Enum.map(&change(&1, roles))

    before_report = Analysis.report(snapshot, baselines)
    after_report = Analysis.report(Simulation.apply_changes(snapshot, changes), baselines)
    diff = ReportDiff.diff(before_report, after_report)

    %__MODULE__{
      problems: problems,
      notes: notes,
      resolved: diff.resolved,
      remaining: diff.remaining,
      introduced: diff.introduced
    }
  end

  defp judge(suggestion, {problems, notes, occupancy}, context) do
    tier = Budget.tier(suggestion.price_usd, context.policy)

    found =
      suggestion
      |> problems(context.snapshot, context.in_main, context.ceilings, context.pipeline)
      |> Enum.concat(List.wrap(quota_problem(suggestion, tier, occupancy, context.policy)))

    if found == [] do
      charged = Budget.charge(occupancy, tier, delta(suggestion))

      {problems, note(notes, suggestion, tier, charged, context.policy), charged}
    else
      {Map.put(problems, key(suggestion), found), notes, occupancy}
    end
  end

  # Balance is judged on the answer's NET, in a pass of its own, and that is
  # not a detail. Cuts come first in a consult's answer, so a running count
  # dips before it recovers: a deck 95 cards short would have had every cut
  # refused for "moving away from 100" before reaching the adds that pay for
  # them. A swap is not a drift.
  #
  # The engine caps; it never demands. It refuses the surplus on the offending
  # side — the last ones proposed, so the stage keeps its best-argued changes —
  # and no rule here can make a model want to cut a card. The briefing asks for
  # the direction; this only stops the copy drifting further from 100 than it
  # started.
  defp balance_problems(_suggestions, _problems, %{card_count: nil}), do: %{}

  defp balance_problems(suggestions, problems, context) do
    clean = Enum.reject(suggestions, &(&1.resolved? == false or Map.has_key?(problems, key(&1))))
    {adds, cuts} = Enum.split_with(clean, &(&1.action == :add))

    surplus =
      Balance.surplus(length(adds) - length(cuts), context.card_count, context.balance_mode)

    case surplus do
      {:add, count} -> refuse_last(adds, count, :add)
      {:cut, count} -> refuse_last(cuts, count, :cut)
      :none -> %{}
    end
  end

  defp refuse_last(suggestions, count, action) do
    suggestions
    |> Enum.take(-count)
    |> Map.new(&{key(&1), [Balance.refusal(action)]})
  end

  defp delta(%Suggestion{action: :add}), do: 1
  defp delta(%Suggestion{action: :cut}), do: -1

  # Cutting an expensive card frees its slot; only an add can run out of room.
  defp quota_problem(%Suggestion{action: :cut}, _tier, _occupancy, _policy), do: nil
  defp quota_problem(_suggestion, nil, _occupancy, _policy), do: nil

  defp quota_problem(suggestion, tier, occupancy, policy) do
    if Budget.room?(occupancy, tier, policy) do
      nil
    else
      full_message(tier, occupancy, policy, suggestion)
    end
  end

  defp full_message(:exception, _occupancy, policy, suggestion) do
    "#{Money.brl(suggestion.price_usd)} passa do teto de R$ #{policy.exception.threshold} " <>
      "e as #{policy.exception.max} vaga(s) de exceção já estão ocupadas"
  end

  defp full_message(:expensive, _occupancy, policy, _suggestion) do
    "o deck já tem #{policy.expensive.max} carta(s) acima de R$ " <>
      "#{policy.expensive.threshold}, o limite que você pôs"
  end

  # What the engine wants to SAY, kept away from what it wants to refuse. An
  # exception is the owner's own rule being broken on purpose, and the one
  # thing he should never learn by accident is that he just spent the last one.
  defp note(notes, _suggestion, nil, _occupancy, _policy), do: notes
  defp note(notes, %Suggestion{action: :cut}, _tier, _occupancy, _policy), do: notes

  defp note(notes, suggestion, tier, occupancy, policy) do
    case policy[tier].max do
      nil -> notes
      max -> Map.put(notes, key(suggestion), [slot_message(tier, occupancy[tier], max)])
    end
  end

  defp slot_message(:exception, used, max) do
    "exceção #{used} de #{max} — acima do teto, e é você quem decide se compensa"
  end

  defp slot_message(:expensive, used, max), do: "carta cara #{used} de #{max}"

  defp key(%Suggestion{action: action, name: name}), do: {action, name}

  # The three rules that only exist inside an optimization run, where nobody
  # is clicking per-suggestion and the engine is the only gate.
  defp pipeline_opts(opts) do
    %{
      flips:
        opts |> Keyword.get(:history, []) |> Enum.frequencies_by(&Name.normalize(&1["card"])),
      # Cards the owner named himself. The churn guard exists to stop two
      # models arguing in circles; a person who says "you misread this card"
      # is not churn, and the guard was never about him.
      exempt: opts |> Keyword.get(:exempt, []) |> MapSet.new(&Name.normalize/1),
      keep: opts |> Keyword.get(:keep, []) |> MapSet.new(&Name.normalize/1),
      bracket_max: Keyword.get(opts, :bracket_max),
      avoid: Keyword.get(opts, :avoid, %{}),
      budget: Keyword.get(opts, :budget),
      spent: Keyword.get(opts, :spent, Decimal.new(0))
    }
  end

  # Ping-pong is chained critics' known failure mode, and it is countable.
  # One appearance in the history is a change; a second is the revert — the
  # legitimate disagreement. A third touch is churn, and the engine ends it.
  defp flip_flop_problem(%{flips: flips, exempt: exempt}, name) do
    key = Name.normalize(name)

    if Map.get(flips, key, 0) >= 2 and not MapSet.member?(exempt, key) do
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

  # Taste, not power. The owner said they do not want this kind of card at
  # their table, and inside a pipeline nobody is there to click "no". Only
  # `evitar` reaches here — wanting a tactic is an invitation in the briefing,
  # because no engine can force a model to have an idea.
  # Per-card ceilings answer "is this one card too expensive". They cannot
  # answer "what is this whole round costing me", which is the question an
  # owner with a real budget actually has.
  defp budget_problem(_price, %{budget: nil}), do: nil
  defp budget_problem(nil, _pipeline), do: nil

  defp budget_problem(price_usd, %{budget: budget, spent: spent}) do
    running = Decimal.add(spent, Money.to_brl(price_usd) || Decimal.new(0))

    if Decimal.gt?(running, Decimal.new(budget)) do
      "passaria o orçamento da rodada: #{Money.brl(price_usd)} levaria o total a " <>
        "R$ #{Decimal.round(running, 2)} de um teto de R$ #{budget}"
    end
  end

  defp salt_problem(entry_roles, %{avoid: avoid}) do
    case Enum.find(avoid, fn {role, _label} -> role in entry_roles end) do
      {_role, label} -> "você marcou evitar #{label} nesta rodada"
      nil -> nil
    end
  end

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
        salt_problem(entry_roles, pipeline),
        budget_problem(suggestion.price_usd, pipeline),
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
      "#{Money.brl(price_usd)} passa do teto de R$ #{ceiling}"
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
  # Only the ceiling case is a problem: a Game Changer with headroom is a
  # legal, ordinary add, and at a bracket 4 floor they are unrestricted. A
  # "problem" excludes the suggestion from the simulation, so informational
  # notes must not masquerade as one — that mistake silently kept legitimate
  # adds out of the measured before→after.
  defp bracket_problem(%Card{game_changer: true}, snapshot) do
    bracket = Bracket.floor(snapshot)

    case Bracket.game_changer_headroom(bracket) do
      0 -> "é Game Changer — seria o 4º e tira o deck do Bracket 3"
      _room_or_floor4 -> nil
    end
  end

  defp bracket_problem(_card, _snapshot), do: nil

  defp change(%Suggestion{action: :cut, name: name}, _roles), do: {:cut, Name.normalize(name)}

  defp change(%Suggestion{action: :add, card: card}, roles) do
    {:add, CardEntry.new(card, 1, Map.get(roles, card.id, []))}
  end
end
