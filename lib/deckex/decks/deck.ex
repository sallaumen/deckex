defmodule Deckex.Decks.Deck do
  @moduledoc """
  A Commander deck the user tracks.

  `raw_decklist` keeps the text the deck was built from. It costs a column and
  buys re-import without bothering the user: when the parser or the rules
  improve, the deck can be rebuilt from what was originally pasted.
  """
  use Deckex.Schema

  import Ecto.Changeset

  @fields ~w(name moxfield_url moxfield_public_id source color_identity status
             raw_decklist last_synced_at last_error notes archived_at description
             dossier dossier_source dossier_stale dossier_updated_at)a
  @required ~w(name source status)a

  @type t :: %__MODULE__{}

  schema "decks" do
    field :name, :string
    field :moxfield_url, :string
    field :moxfield_public_id, :string
    field :source, Ecto.Enum, values: [:moxfield, :paste]
    field :color_identity, {:array, :string}, default: []
    field :status, Ecto.Enum, values: [:importing, :enriching, :classifying, :ready, :failed]
    field :raw_decklist, :string
    field :last_synced_at, :utc_datetime
    field :last_error, :string
    field :notes, :string
    field :archived_at, :utc_datetime

    # His words about what this deck is for. Not the dossier: the dossier is
    # the app's reading and a consult rewrites it, this is his and nothing
    # overwrites it.
    field :description, :string

    # The scout's strategic reading — see the 2026-08-14 meta-prompt spec.
    field :dossier, :map
    field :dossier_source, Ecto.Enum, values: [:scout, :manual]
    field :dossier_stale, :boolean, default: false
    field :dossier_updated_at, :utc_datetime

    timestamps()
  end

  @doc "Builds a changeset for a deck."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(deck, attrs) do
    deck
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> unique_constraint(:moxfield_public_id, name: :decks_moxfield_public_id_index)
  end
end
