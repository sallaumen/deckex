defmodule Deckex.Decks.DeckCard do
  @moduledoc """
  One card in a deck, on one board. The commander lives on the `:commander`
  board rather than in a column on `decks`, so partner commanders need no schema
  change.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Cards.Card
  alias Deckex.Decks.Deck

  @type t :: %__MODULE__{}

  schema "deck_cards" do
    field :quantity, :integer, default: 1
    field :board, Ecto.Enum, values: [:main, :commander, :maybe]

    belongs_to :deck, Deck
    belongs_to :card, Card

    timestamps()
  end

  @doc "Builds a changeset for a card on a board."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(deck_card, attrs) do
    deck_card
    |> cast(attrs, [:deck_id, :card_id, :quantity, :board])
    |> validate_required([:deck_id, :card_id, :quantity, :board])
    |> validate_number(:quantity, greater_than: 0)
    |> foreign_key_constraint(:deck_id)
    |> foreign_key_constraint(:card_id)
    |> unique_constraint([:deck_id, :card_id, :board])
  end
end
