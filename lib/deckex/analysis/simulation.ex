defmodule Deckex.Analysis.Simulation do
  @moduledoc """
  Applies a set of proposed changes to a snapshot, in memory.

  This is how an AI answer stops being a claim: apply its cuts and adds to the
  snapshot, re-run the report, and the difference is measured, not asserted.
  Pure like everything in `Deckex.Analysis` — entries in, entries out.

  Inapplicable changes are **skipped, never raised**: a cut of a card that is
  not in the list, or an add that would repeat a singleton card, silently
  leaves the snapshot alone here. Naming those problems is the legality
  audit's job (`Deckex.Consults.Audit`); measuring what the applicable rest
  would do is this module's. Two concerns, two outputs.
  """

  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Cards.Card
  alias Deckex.Cards.Name

  @type change :: {:cut, String.t()} | {:add, CardEntry.t()}

  @doc """
  Applies `changes` to the main board. Cuts take one copy by normalized name;
  adds append an entry, or bump the quantity of an already-present basic land.
  Commanders are never touched — no consult may cut the commander.
  """
  @spec apply_changes(DeckSnapshot.t(), [change()]) :: DeckSnapshot.t()
  def apply_changes(%DeckSnapshot{} = snapshot, changes) do
    %{snapshot | main: Enum.reduce(changes, snapshot.main, &apply_change/2)}
  end

  defp apply_change({:cut, normalized}, main) do
    case Enum.split_with(main, &(key(&1) == normalized)) do
      {[], _rest} -> main
      {[entry | dupes], rest} -> drop_one(entry) ++ dupes ++ rest
    end
  end

  defp apply_change({:add, %CardEntry{} = added}, main) do
    case Enum.split_with(main, &(key(&1) == key(added))) do
      {[], _rest} ->
        [added | main]

      {[existing | dupes], rest} ->
        if Card.basic_land?(existing.card) or Card.any_number_allowed?(existing.card) do
          [%{existing | quantity: existing.quantity + added.quantity} | dupes] ++ rest
        else
          main
        end
    end
  end

  defp drop_one(%CardEntry{quantity: 1}), do: []
  defp drop_one(%CardEntry{} = entry), do: [%{entry | quantity: entry.quantity - 1}]

  defp key(%CardEntry{card: card}), do: Name.normalize(card.name)
end
