defmodule Deckex.Decks.Edits do
  @moduledoc """
  The changes waiting to become a version.

  Every card the owner puts in or takes out is logged here with the reason it
  happened — the consult's own sentence when a suggestion was applied, nothing
  when it was typed by hand. The next version marked reads this list and
  empties it.

  The list is not the truth about the deck: `deck_cards` is. If the two ever
  disagree — a restore, a run applied, a row lost — the version falls back to
  diffing the lists, which is always right about *what* changed and silent
  about *why*. That is the trade this module exists to improve on, never to
  replace.
  """

  import Ecto.Query

  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckEdit
  alias Deckex.Repo

  @doc """
  Records one change. `opts` carries `:reason` and `:consult_id`.

  Never fails the caller's operation: the card is already in or out of the
  deck by the time this runs, and losing the note is not worth losing the edit.
  """
  @spec log(Deck.t(), :add | :cut, String.t(), keyword()) :: :ok
  def log(%Deck{} = deck, action, card_name, opts \\ []) do
    %DeckEdit{}
    |> DeckEdit.changeset(%{
      deck_id: deck.id,
      action: action,
      card_name: card_name,
      reason: Keyword.get(opts, :reason),
      consult_id: Keyword.get(opts, :consult_id)
    })
    |> Repo.insert!()

    :ok
  end

  @doc "Every change waiting on this deck, oldest first."
  @spec pending(Deck.t()) :: [DeckEdit.t()]
  def pending(%Deck{id: deck_id}) do
    Repo.all(from e in DeckEdit, where: e.deck_id == ^deck_id, order_by: [asc: e.inserted_at])
  end

  @doc "How many changes are waiting — the number the deck page shows."
  @spec count(Deck.t()) :: non_neg_integer()
  def count(%Deck{id: deck_id}) do
    Repo.aggregate(from(e in DeckEdit, where: e.deck_id == ^deck_id), :count)
  end

  @doc """
  The pending changes as a changelog, netted the way every changelog here is.

  A card put in and taken out again before anyone marked a version did not
  happen to the deck, and the history should not claim it did.
  """
  @spec changelog(Deck.t()) :: [map()]
  def changelog(%Deck{} = deck) do
    deck
    |> pending()
    |> Enum.map(&DeckEdit.to_change/1)
    |> Enum.group_by(& &1["card"])
    |> Enum.flat_map(fn {_card, touches} -> surviving(touches) end)
    |> Enum.sort_by(&{&1["action"], &1["card"]})
  end

  defp surviving(touches) do
    {adds, cuts} = Enum.split_with(touches, &(&1["action"] == "add"))
    net = length(adds) - length(cuts)

    cond do
      net > 0 -> Enum.take(adds, -net)
      net < 0 -> Enum.take(cuts, net)
      true -> []
    end
  end

  @doc "Forgets every pending change on a deck — called by whatever recorded them."
  @spec clear(Deck.t()) :: :ok
  def clear(%Deck{id: deck_id}) do
    Repo.delete_all(from e in DeckEdit, where: e.deck_id == ^deck_id)

    :ok
  end
end
