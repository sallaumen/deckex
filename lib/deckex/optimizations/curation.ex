defmodule Deckex.Optimizations.Curation do
  @moduledoc """
  The Bancada: what the owner did with the vacancies he was offered.

  Every other mode ends with the model choosing cards and the engine refusing
  the illegal ones. This one moves the act of choosing to the owner, who is the
  only party in the system that has played the deck — so the stage that would
  have made the changes lays out vacancies instead (`Deckex.Consults.Vacancies`),
  and this module holds what he does with them.

  `selections` is what he chose; `applied` is what the audit let through. The
  two are kept apart for the same reason `rejected` exists: a refusal is the
  engine doing its job, and the record of it has to survive.

  Pure. Persisting a decision and auditing a board are `Deckex.Optimizations`'
  job, the same as everything else that writes.
  """

  alias Deckex.Consults.Suggestion
  alias Deckex.Consults.Vacancy
  alias Deckex.Optimizations.OptimizationStep

  @doc """
  What the owner picked for one vacancy: a card name, or `nil` for a skip.

  A skip and an undecided vacancy are different answers and stay different — a
  board that collapsed them would tell him he had finished when he had not.
  """
  @spec decision(OptimizationStep.t(), Vacancy.t()) :: String.t() | nil | :undecided
  def decision(%OptimizationStep{selections: selections}, %Vacancy{key: key}) do
    case Map.fetch(selections || %{}, key) do
      {:ok, name} -> name
      :error -> :undecided
    end
  end

  @doc """
  The selections map with one vacancy answered.

  Picking the card that is already picked clears it: on a board where every
  click is reversible, the second click on the same candidate can only mean
  "actually, no".
  """
  @spec put(OptimizationStep.t(), Vacancy.t(), String.t() | nil) :: map()
  def put(%OptimizationStep{selections: selections} = step, %Vacancy{key: key} = vacancy, name) do
    if name != nil and decision(step, vacancy) == name do
      Map.put(selections || %{}, key, nil)
    else
      Map.put(selections || %{}, key, name)
    end
  end

  @doc "The selections map with one vacancy back to undecided."
  @spec clear(OptimizationStep.t(), Vacancy.t()) :: map()
  def clear(%OptimizationStep{selections: selections}, %Vacancy{key: key}) do
    Map.delete(selections || %{}, key)
  end

  @doc """
  The owner's choices as suggestions, ready for the same audit every stage gets.

  Cuts first, exactly like a model's answer, because the audit's budget fold
  counts a slot freed by a cut before it judges the adds that might want it.

  The reason carries **both** halves — the need and the card. A changelog read
  a month later wants to know what the hole was, and the candidate's own
  sentence only ever says why this card and not its neighbour.
  """
  @spec chosen(OptimizationStep.t(), [Vacancy.t()]) :: [Suggestion.t()]
  def chosen(%OptimizationStep{} = step, vacancies) do
    step |> picks(vacancies) |> Enum.map(&elem(&1, 1))
  end

  @doc """
  The same picks, each still holding the vacancy it came from.

  `Suggestion` is the shape every stage's answer takes and it has no business
  knowing about boards, so the vacancy travels beside it rather than inside it.
  """
  @spec picks(OptimizationStep.t(), [Vacancy.t()]) :: [{Vacancy.t(), Suggestion.t()}]
  def picks(%OptimizationStep{} = step, vacancies) do
    vacancies
    |> Enum.sort_by(&{&1.action == :add, &1.index})
    |> Enum.flat_map(fn vacancy ->
      with name when is_binary(name) <- decision(step, vacancy),
           %Vacancy.Candidate{} = candidate <- Enum.find(vacancy.candidatos, &(&1.name == name)) do
        [{vacancy, suggestion(vacancy, candidate)}]
      else
        _skipped_or_undecided_or_gone -> []
      end
    end)
  end

  defp suggestion(%Vacancy{} = vacancy, %Vacancy.Candidate{} = candidate) do
    %Suggestion{
      action: vacancy.action,
      name: candidate.name,
      reason: reason(vacancy, candidate),
      addresses: vacancy.grupo,
      card: candidate.card,
      price_usd: candidate.price_usd,
      resolved?: candidate.resolved?
    }
  end

  defp reason(%Vacancy{vaga: ""}, %Vacancy.Candidate{porque: porque}), do: porque
  defp reason(%Vacancy{vaga: vaga}, %Vacancy.Candidate{porque: ""}), do: vaga
  defp reason(%Vacancy{vaga: vaga}, %Vacancy.Candidate{porque: porque}), do: "#{vaga} — #{porque}"

  @doc """
  The choices that will actually change the list, and the ones that cannot.

  Two vacancies may offer the same card — the reserve deliberately re-offers a
  basic — and the owner may take both. The engine's `apply_change/2` removes
  one copy and silently does nothing for the second, so a board that counted
  both as `-1` told him he was at 106 while the list it would produce held
  107. **The count is the one number this screen exists to be right about**, so
  a cut is effective only while the list still has a copy for it to take.

  Deterministic and copies-aware: the picks are walked in `chosen/2`'s order
  against a budget of the copies the list actually holds. An add is always
  effective — the singleton rule is the audit's job, and it enforces it.
  """
  @spec settle(OptimizationStep.t(), [Vacancy.t()], [map()]) ::
          {[Suggestion.t()], [String.t()]}
  def settle(%OptimizationStep{} = step, vacancies, list) do
    copies =
      Enum.reduce(list, %{}, fn row, acc ->
        Map.update(acc, key(row["name"]), row["quantity"] || 1, &(&1 + (row["quantity"] || 1)))
      end)

    {effective, surplus, _left} =
      step
      |> picks(vacancies)
      |> Enum.reduce({[], [], copies}, fn
        {_vacancy, %Suggestion{action: :add} = pick}, {ok, no, left} ->
          {[pick | ok], no, left}

        {vacancy, %Suggestion{action: :cut} = pick}, {ok, no, left} ->
          case Map.get(left, key(pick.name), 0) do
            n when n > 0 -> {[pick | ok], no, Map.put(left, key(pick.name), n - 1)}
            _none_left -> {ok, [vacancy.key | no], left}
          end
      end)

    {Enum.reverse(effective), Enum.reverse(surplus)}
  end

  defp key(name), do: name |> to_string() |> String.downcase() |> String.trim()

  @doc """
  The vacancy keys whose cut cannot land, because no copy is left for it.

  What the board paints on the tile: the pick stands, but it moves nothing,
  and a screen that let him believe otherwise would be lying about the only
  number it exists to get right.
  """
  @spec surplus_keys(OptimizationStep.t(), [Vacancy.t()], [map()]) :: MapSet.t()
  def surplus_keys(%OptimizationStep{} = step, vacancies, list) do
    {_effective, surplus} = settle(step, vacancies, list)
    MapSet.new(surplus)
  end

  @doc "Cards in minus cards out. What the count gate reads."
  @spec net(OptimizationStep.t(), [Vacancy.t()], [map()]) :: integer()
  def net(%OptimizationStep{} = step, vacancies, list) do
    {effective, _surplus} = settle(step, vacancies, list)

    Enum.reduce(effective, 0, fn
      %Suggestion{action: :add}, total -> total + 1
      %Suggestion{action: :cut}, total -> total - 1
    end)
  end

  @doc "Where this board would leave the sandbox's card count."
  @spec count(OptimizationStep.t(), [Vacancy.t()], non_neg_integer(), [map()]) :: integer()
  def count(%OptimizationStep{} = step, vacancies, starting, list) do
    starting + net(step, vacancies, list)
  end

  @doc "How many vacancies still have no answer of any kind."
  @spec undecided(OptimizationStep.t(), [Vacancy.t()]) :: non_neg_integer()
  def undecided(%OptimizationStep{} = step, vacancies) do
    Enum.count(vacancies, &(decision(step, &1) == :undecided))
  end

  @doc """
  Whether the count already needs the reserve cuts.

  It opens by itself the moment he is carrying more entries than the principal
  cuts can pay for. The alternative was a board that told him to cut more and
  had nowhere for him to do it.
  """
  @spec reserve_open?(OptimizationStep.t(), [Vacancy.t()]) :: boolean()
  def reserve_open?(%OptimizationStep{} = step, vacancies) do
    carrying =
      step
      |> chosen(vacancies)
      |> Enum.reduce(0, fn
        %Suggestion{action: :add}, total -> total + 1
        %Suggestion{action: :cut}, total -> total - 1
      end)

    carrying > 0 or Enum.any?(vacancies, &(&1.reserve? and decided?(step, &1)))
  end

  defp decided?(step, vacancy), do: decision(step, vacancy) != :undecided

  @doc "The vacancies the board shows, with the reserve folded away until needed."
  @spec visible(OptimizationStep.t(), [Vacancy.t()]) :: [Vacancy.t()]
  def visible(%OptimizationStep{} = step, vacancies) do
    if reserve_open?(step, vacancies) do
      vacancies
    else
      Enum.reject(vacancies, & &1.reserve?)
    end
  end

  @doc """
  Why this board cannot be committed yet, in the owner's language, or nil.

  One refusal only, and only at the cardápio: choosing nothing is not a small
  round, it is no round, and closing it would spend the critic's consult
  saying so. The COUNT does not block — the owner chooses freely, and a copy
  left off 100 is what the balance stages exist to close, informed by every
  decision he just made. He asked for exactly this, in as many words: pick
  and drop without arithmetic in the way, and let the engine settle the
  hundred afterwards. At the critic's gate even an empty board passes: that
  is him declining the corrections, which is the whole point of the mode.
  """
  @spec blocker(OptimizationStep.t(), [Vacancy.t()], non_neg_integer()) :: String.t() | nil
  def blocker(%OptimizationStep{} = step, vacancies, _starting) do
    if step.kind == :cardapio and chosen(step, vacancies) == [] do
      "Você ainda não escolheu nada. Escolha ao menos uma carta para fechar a rodada."
    end
  end
end
