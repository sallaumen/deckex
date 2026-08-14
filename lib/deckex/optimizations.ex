defmodule Deckex.Optimizations do
  @moduledoc """
  The Otimizador: a pipeline of AI stages over a sandbox copy of a deck.

  Each stage consults a model through one lens, the engine audits the answer,
  and the clean changes are applied automatically — **to the sandbox, never to
  the real deck**. Later stages see everything earlier stages did and may
  revert it once, with a reason; the audit's flip-flop guard stops churn.

  See `docs/superpowers/specs/2026-08-14-otimizador-design.md`.
  """

  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Cards
  alias Deckex.Cards.Name
  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckQuery
  alias Deckex.Optimizations.OptimizationQuery
  alias Deckex.Optimizations.OptimizationStep

  @doc "The deck's current main board and commanders, as sandbox data."
  @spec list_from_deck(Deck.t()) :: %{list: [map()], commanders: [String.t()]}
  def list_from_deck(%Deck{} = deck) do
    grouped = deck |> DeckQuery.list_deck_cards() |> Enum.group_by(& &1.board)

    %{
      list:
        grouped
        |> Map.get(:main, [])
        |> Enum.map(&%{"name" => &1.card.name, "quantity" => &1.quantity}),
      commanders: grouped |> Map.get(:commander, []) |> Enum.map(& &1.card.name)
    }
  end

  @doc """
  Applies a stage's accepted changes to a sandbox list. Pure list arithmetic —
  the audit already vetted legality, singleton and the rest before anything
  reaches here.
  """
  @spec apply_changes_to_list([map()], [map()]) :: [map()]
  def apply_changes_to_list(list, changes) do
    Enum.reduce(changes, list, &apply_change/2)
  end

  @doc """
  The sandbox as a stage left it — its `list_before` plus its `applied`
  changes. Derived, never stored: one source of truth.
  """
  @spec list_after(OptimizationStep.t()) :: [map()]
  def list_after(%OptimizationStep{} = step) do
    apply_changes_to_list(step.list_before || [], step.applied || [])
  end

  @doc """
  Builds the snapshot the analysis engine reads, from a sandbox list.

  Cards and roles come from the catalogue; anything a stage added was
  catalogued when its consult finished. A list entry whose card is missing
  from the catalogue is skipped — the same behaviour as import.
  """
  @spec snapshot_for([map()], [String.t()], Deck.t()) :: DeckSnapshot.t()
  def snapshot_for(list, commanders, %Deck{} = deck) do
    names = Enum.map(list, & &1["name"]) ++ commanders
    cards = Cards.list_by_normalized_names(Enum.map(names, &Name.normalize/1))
    roles = cards |> Enum.map(& &1.id) |> Cards.roles_by_card_ids()
    by_key = Map.new(cards, &{&1.name_normalized, &1})

    %DeckSnapshot{
      deck_id: deck.id,
      deck_name: deck.name,
      color_identity: deck.color_identity,
      commanders: entries(Enum.map(commanders, &%{"name" => &1, "quantity" => 1}), by_key, roles),
      main: entries(list, by_key, roles)
    }
  end

  @doc """
  A sandbox list as decklist text `Decks.import_from_text/2` round-trips —
  the commander section first, in the convention the parser reads.
  """
  @spec list_to_text([map()], [String.t()]) :: String.t()
  def list_to_text(list, commanders) do
    commander_block =
      case commanders do
        [] -> ""
        names -> "Commander:\n" <> Enum.map_join(names, "\n", &"1 #{&1}") <> "\n\n"
      end

    commander_block <> Enum.map_join(list, "\n", &"#{&1["quantity"]} #{&1["name"]}")
  end

  defp entries(rows, by_key, roles) do
    Enum.flat_map(rows, fn row ->
      case Map.get(by_key, Name.normalize(row["name"])) do
        nil -> []
        card -> [CardEntry.new(card, row["quantity"], Map.get(roles, card.id, []))]
      end
    end)
  end

  defp apply_change(%{"action" => "add", "card" => name}, list) do
    case Enum.split_with(list, &same_card?(&1, name)) do
      {[], _rest} ->
        list ++ [%{"name" => name, "quantity" => 1}]

      {[existing | dupes], rest} ->
        [%{existing | "quantity" => existing["quantity"] + 1} | dupes] ++ rest
    end
  end

  defp apply_change(%{"action" => "cut", "card" => name}, list) do
    case Enum.split_with(list, &same_card?(&1, name)) do
      {[], _rest} ->
        list

      {[%{"quantity" => 1} | dupes], rest} ->
        dupes ++ rest

      {[existing | dupes], rest} ->
        [%{existing | "quantity" => existing["quantity"] - 1} | dupes] ++ rest
    end
  end

  defp same_card?(row, name), do: Name.normalize(row["name"]) == Name.normalize(name)

  defdelegate fetch_run(id), to: __MODULE__, as: :fetch

  @doc "One run with its steps, or a not-found error."
  @spec fetch(String.t()) ::
          {:ok, Deckex.Optimizations.Optimization.t()} | {:error, Deckex.Error.t()}
  def fetch(id) do
    case OptimizationQuery.get(id) do
      nil -> {:error, Deckex.Error.new(:optimization_not_found, "Não achei essa otimização.")}
      optimization -> {:ok, optimization}
    end
  end

  defdelegate list_for_deck(deck_id), to: OptimizationQuery
end
