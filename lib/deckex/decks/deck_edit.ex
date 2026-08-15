defmodule Deckex.Decks.DeckEdit do
  @moduledoc """
  One change made to a deck since its last version, and why.

  It exists so that a version marked later can say "− Sol Ring — muito lento
  para o plano do deck (consulta de mana)" rather than "− Sol Ring — editado à
  mão". Comparing two lists can recover *what* changed; only the moment of the
  change knows *why*.

  Rows are consumed — deleted — by the version that records them. This is a
  pending changelog, not a ledger.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Consults.Consult
  alias Deckex.Decks.Deck

  @fields ~w(deck_id action card_name reason consult_id)a
  @required ~w(deck_id action card_name)a

  @type t :: %__MODULE__{}

  schema "deck_edits" do
    belongs_to :deck, Deck
    belongs_to :consult, Consult

    field :action, Ecto.Enum, values: [:add, :cut]
    field :card_name, :string
    field :reason, :string

    timestamps()
  end

  @doc "Builds a changeset for one edit."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(edit, attrs) do
    edit
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end

  @doc "The edit in the shape every changelog in this app uses."
  @spec to_change(t()) :: map()
  def to_change(%__MODULE__{} = edit) do
    %{
      "action" => Atom.to_string(edit.action),
      "card" => edit.card_name,
      "reason" => edit.reason || "editado à mão"
    }
  end
end
