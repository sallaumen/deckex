defmodule Deckex.Analysis.DeckSnapshot do
  @moduledoc """
  Everything the lenses need about a deck, already loaded.

  This struct is the boundary that keeps `Deckex.Analysis` pure: the database
  work happens once in `Deckex.Decks.snapshot/1`, and every lens then operates
  on plain structs in memory.
  """

  alias Deckex.Analysis.CardEntry

  @type t :: %__MODULE__{
          deck_id: String.t(),
          deck_name: String.t(),
          color_identity: [String.t()],
          commanders: [CardEntry.t()],
          main: [CardEntry.t()]
        }

  @enforce_keys [:deck_id, :deck_name, :color_identity, :commanders, :main]
  defstruct [:deck_id, :deck_name, :color_identity, :commanders, :main]

  @doc "Main-deck entries whose front face is a land."
  @spec lands(t()) :: [CardEntry.t()]
  def lands(%__MODULE__{main: main}), do: Enum.filter(main, &CardEntry.land?/1)

  @doc "Main-deck entries whose front face is not a land."
  @spec nonlands(t()) :: [CardEntry.t()]
  def nonlands(%__MODULE__{main: main}), do: Enum.reject(main, &CardEntry.land?/1)

  @doc "Main-deck spells whose back face is a land."
  @spec mdfc_lands(t()) :: [CardEntry.t()]
  def mdfc_lands(%__MODULE__{main: main}), do: Enum.filter(main, &CardEntry.mdfc_land?/1)

  @doc "Sums copies, not rows — four Forests are four cards."
  @spec count([CardEntry.t()]) :: non_neg_integer()
  def count(entries), do: Enum.sum(Enum.map(entries, & &1.quantity))

  @doc "The entries holding `kind`."
  @spec with_role([CardEntry.t()], atom()) :: [CardEntry.t()]
  def with_role(entries, kind), do: Enum.filter(entries, &CardEntry.has_role?(&1, kind))

  @doc "Card names, sorted — what a finding shows the user."
  @spec names([CardEntry.t()]) :: [String.t()]
  def names(entries), do: entries |> Enum.map(& &1.card.name) |> Enum.sort()
end
