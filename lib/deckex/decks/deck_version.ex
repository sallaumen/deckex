defmodule Deckex.Decks.DeckVersion do
  @moduledoc """
  A photograph of a deck at a moment, and the story of how it got there.

  The deck's own `deck_cards` stay the working state — what every lens measures
  and what the page edits. A version is history beside it: never measured,
  never joined, only read back when the owner wants to see what changed or to
  return to it.

  That is why `list` is jsonb rather than rows. It is also the shape the
  optimizer's sandbox already uses, and one representation of a decklist is one
  place for a bug about decklists to live.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Decks.Deck

  @fields ~w(deck_id number origin label optimization_id list commanders changes)a
  @required ~w(deck_id number origin list)a

  @type t :: %__MODULE__{}

  schema "deck_versions" do
    belongs_to :deck, Deck

    field :number, :integer

    # Where this version came from, which is what the history reads as: the
    # import it arrived in, a run that was applied, or the owner marking a
    # moment worth returning to.
    field :origin, Ecto.Enum, values: [:import, :optimization, :manual]
    field :label, :string
    field :optimization_id, Ecto.UUID

    # `%{"rows" => [%{"name", "quantity"}]}` — wrapped in a map because the
    # column is jsonb and a bare array is a different beast to migrate later.
    field :list, :map
    field :commanders, {:array, :string}, default: []

    # `%{"applied" => [%{"action", "card", "reason"}]}` — what this version did
    # to the one before it. Empty on the first.
    field :changes, :map, default: %{}

    timestamps()
  end

  @doc "Builds a changeset for a version."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(version, attrs) do
    version
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> unique_constraint([:deck_id, :number], name: :deck_versions_deck_id_number_index)
  end

  @doc "The rows of the main list, as the sandbox shapes them."
  @spec rows(t()) :: [map()]
  def rows(%__MODULE__{list: list}), do: Map.get(list || %{}, "rows", [])

  @doc "What this version did to the one before it."
  @spec applied(t()) :: [map()]
  def applied(%__MODULE__{changes: changes}), do: Map.get(changes || %{}, "applied", [])

  @doc "How many cards this version holds, commanders included."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = version) do
    quantities = version |> rows() |> Enum.map(&(&1["quantity"] || 0)) |> Enum.sum()

    quantities + length(version.commanders)
  end
end
