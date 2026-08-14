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
  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Analysis.Finding
  alias Deckex.Analysis.ReportDiff
  alias Deckex.Analysis.Simulation
  alias Deckex.Cards.Card
  alias Deckex.Cards.Name
  alias Deckex.Consults.Suggestion

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
  @spec run(DeckSnapshot.t(), [Suggestion.t()], %{String.t() => list()}, Baselines.t()) :: t()
  def run(%DeckSnapshot{} = snapshot, suggestions, roles, %Baselines{} = baselines) do
    in_main = MapSet.new(snapshot.main, &Name.normalize(&1.card.name))

    problems =
      suggestions
      |> Enum.map(&{key(&1), problems(&1, snapshot, in_main)})
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

  # An unresolved suggestion has no card data to check; the table already
  # marks it and the simulation cannot use it.
  defp problems(%Suggestion{resolved?: false}, _snapshot, _in_main), do: []

  defp problems(%Suggestion{action: :cut} = suggestion, _snapshot, in_main) do
    if MapSet.member?(in_main, Name.normalize(suggestion.name)) do
      []
    else
      ["não está na lista principal"]
    end
  end

  defp problems(%Suggestion{action: :add, card: card} = suggestion, snapshot, in_main) do
    Enum.reject(
      [
        identity_problem(card, snapshot.color_identity),
        singleton_problem(card, suggestion, in_main),
        legality_problem(card)
      ],
      &is_nil/1
    )
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

  defp change(%Suggestion{action: :cut, name: name}, _roles), do: {:cut, Name.normalize(name)}

  defp change(%Suggestion{action: :add, card: card}, roles) do
    {:add, CardEntry.new(card, 1, Map.get(roles, card.id, []))}
  end
end
