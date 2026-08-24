defmodule Deckex.Decks.CardNote do
  @moduledoc """
  One thing the owner has decided about one card in one deck.

  It is not a rules oracle and not a global fact — it is what *this* card does
  *in this list*, in his words. "Jaheira turns Food into creatures that tap for
  mana" is a rules correction; "Sam stays, he is the point of the deck" is a
  preference; both belong here, and both are worth carrying into every future
  briefing about this deck.

  The `stance` is what he wants **done** about it, and it is the difference
  between advice and an order:

    * `:locked` — the card stays. The audit refuses any cut of it, in every
      run of this deck, forever. This is the only stance the engine enforces.
    * `:wanted` — he is asking for the card. Every briefing carries it as his
      request; a stage may still decline, but it has to say so by name.
    * `:note` — what this table has always held: his words, no order attached.

  A locked or wanted card may carry no text at all. An order does not need a
  justification to be an order — though the text is the part that stops the
  next run making the same mistake, so the screen asks for it.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Decks.Deck

  @fields ~w(deck_id card_name note stance source)a
  @required ~w(deck_id card_name)a

  @stances [:locked, :wanted, :note]

  @type stance :: :locked | :wanted | :note
  @type t :: %__MODULE__{}

  schema "deck_card_notes" do
    belongs_to :deck, Deck

    field :card_name, :string
    field :note, :string
    field :stance, Ecto.Enum, values: @stances, default: :note
    field :source, Ecto.Enum, values: [:review, :manual], default: :manual

    timestamps()
  end

  @doc "The stances, strongest order first — the order the screens list them in."
  @spec stances() :: [stance()]
  def stances, do: @stances

  @doc "Whether this row carries an explanation, as opposed to a bare order."
  @spec explained?(t()) :: boolean()
  def explained?(%__MODULE__{note: note}), do: is_binary(note) and note != ""

  @doc "Builds a changeset for a rule."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(note, attrs) do
    note
    |> cast(attrs, @fields)
    |> update_change(:note, &trim_to_nil/1)
    |> update_change(:card_name, &String.trim/1)
    |> validate_required(@required)
    |> validate_length(:card_name, min: 1)
    |> require_note_when_only_a_note()
    |> unique_constraint([:deck_id, :card_name],
      name: :deck_card_notes_deck_id_card_name_index
    )
  end

  defp trim_to_nil(nil), do: nil

  defp trim_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # A row with no stance and no text says nothing, and the way to unsay
  # something is to erase the row.
  defp require_note_when_only_a_note(changeset) do
    if get_field(changeset, :stance) == :note do
      validate_required(changeset, [:note])
    else
      changeset
    end
  end
end
