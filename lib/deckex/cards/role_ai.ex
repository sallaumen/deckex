defmodule Deckex.Cards.RoleAI do
  @moduledoc """
  Classifies the cards the rule engine could not place.

  Only residue reaches this module, and every verdict is cached on the card
  forever, so a card is paid for once across every deck the user will ever
  import. The model's answer is filtered against `RoleMatch.kinds/0` and against
  the cards actually asked about — a model that invents a role or a card name
  must not be able to write either into the database.

  AI verdicts are stored at `:medium` confidence. They are good, but they are
  not a regex over a field that says exactly what the card does.
  """

  alias Deckex.AI
  alias Deckex.AI.Ledger
  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch
  alias Deckex.Error

  @doc "The JSON schema the model's answer must satisfy."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "cards" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "roles" => %{
                "type" => "array",
                "items" => %{
                  "type" => "string",
                  "enum" => Enum.map(RoleMatch.kinds(), &to_string/1)
                }
              },
              "reasoning" => %{"type" => "string"}
            },
            "required" => ["name", "roles", "reasoning"]
          }
        }
      },
      "required" => ["cards"]
    }
  end

  @doc """
  Classifies `cards`, returning a map of card **id** to the roles the model
  assigned.
  """
  @spec classify([Card.t()]) :: {:ok, %{String.t() => [RoleMatch.t()]}} | {:error, Error.t()}
  def classify([]), do: {:ok, %{}}

  def classify(cards) do
    by_name = Map.new(cards, &{&1.name, &1})

    case AI.complete(prompt(cards), schema()) do
      {:ok, %{"cards" => results}, usage} ->
        # Classifying cards belongs to no deck and still costs real money, so
        # it lands in the ledger like everything else — otherwise the global
        # meter would quietly understate the bill.
        :ok = Ledger.record(usage, kind: :classification, model: AI.model())

        {:ok, collect(results, by_name)}

      {:ok, _unexpected, usage} ->
        :ok = Ledger.record(usage, kind: :classification, model: AI.model())

        {:ok, %{}}

      {:error, _reason} = error ->
        error
    end
  end

  defp collect(results, by_name) do
    Enum.reduce(results, %{}, fn result, acc ->
      case Map.fetch(by_name, result["name"]) do
        {:ok, card} -> put_matches(acc, card, result)
        :error -> acc
      end
    end)
  end

  defp put_matches(acc, card, result) do
    case matches(result) do
      [] -> acc
      matches -> Map.put(acc, card.id, matches)
    end
  end

  defp matches(result) do
    known = MapSet.new(RoleMatch.kinds(), &to_string/1)
    reasoning = result["reasoning"] || "classificado pela IA"

    result
    |> Map.get("roles", [])
    |> Enum.filter(&MapSet.member?(known, &1))
    |> Enum.map(&RoleMatch.new(String.to_existing_atom(&1), :medium, reasoning))
  end

  defp prompt(cards) do
    kinds = Enum.map_join(RoleMatch.kinds(), ", ", &to_string/1)

    cards_block =
      Enum.map_join(cards, "\n\n", fn card ->
        """
        Name: #{card.name}
        Mana cost: #{card.mana_cost || "none"}
        Type: #{card.type_line}
        Text: #{card.oracle_text || "(none)"}
        """
      end)

    """
    You are classifying Magic: The Gathering cards by the role they play in a
    Commander (EDH) deck. For each card below, return every role that applies.

    Valid roles: #{kinds}

    Guidance on the distinctions that matter:
    - `ramp` is repeatable or permanent mana acceleration. `ritual` is a one-shot
      burst of mana from an instant or sorcery. They are not the same.
    - `cost_reduction` discounts OTHER spells you cast, not the card itself.
    - `fixing` corrects colours; it is separate from producing extra mana.
    - `counter` only counters spells. `spot_removal` answers a permanent that has
      already resolved. Never label a counterspell as removal.
    - Only assign a role you are confident about. An empty list is a valid and
      useful answer.

    Cards:

    #{cards_block}
    """
  end
end
