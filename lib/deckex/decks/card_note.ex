defmodule Deckex.Decks.CardNote do
  @moduledoc """
  One thing the owner has told this app about one card in one deck.

  It is not a rules oracle and not a global fact — it is what *this* card does
  *in this list*, in his words. "Jaheira turns Food into creatures that tap for
  mana" is a rules correction; "Sam stays, he is the point of the deck" is a
  preference; both belong here, and both are worth carrying into every future
  briefing about this deck.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Decks.Deck

  @fields ~w(deck_id card_name note source)a
  @required ~w(deck_id card_name note)a

  @type t :: %__MODULE__{}

  schema "deck_card_notes" do
    belongs_to :deck, Deck

    field :card_name, :string
    field :note, :string
    field :source, Ecto.Enum, values: [:review, :manual], default: :manual

    timestamps()
  end

  @doc "Builds a changeset for a note."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(note, attrs) do
    note
    |> cast(attrs, @fields)
    |> update_change(:note, &String.trim/1)
    |> validate_required(@required)
    |> validate_length(:note, min: 1)
    |> unique_constraint([:deck_id, :card_name],
      name: :deck_card_notes_deck_id_card_name_index
    )
  end
end
