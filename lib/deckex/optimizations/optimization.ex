defmodule Deckex.Optimizations.Optimization do
  @moduledoc """
  One run of the pipeline over one deck's sandbox.

  The contract and the recipe are **frozen at launch** — an optimization whose
  rules drift mid-run is one nobody can reason about afterwards. The sandbox's
  starting list is frozen too; every later state is derived from it by the
  stages' applied changes. The real deck is never written.

  All map/array payloads are string-keyed: they live in JSONB and come back
  string-keyed anyway, so one shape everywhere (the dossier taught this).
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Decks.Deck
  alias Deckex.Optimizations.OptimizationStep

  @fields ~w(deck_id mode status outcome contract recipe list_original commanders finished_at)a
  @required ~w(deck_id mode status contract recipe list_original commanders)a

  @type t :: %__MODULE__{}

  schema "optimizations" do
    field :mode, Ecto.Enum, values: [:livre, :refine, :reimagine, :curadoria], default: :refine

    field :status, Ecto.Enum,
      values: [:running, :awaiting_choice, :paused, :done, :failed, :cancelled]

    field :outcome, :string
    field :contract, :map
    field :recipe, {:array, :map}
    field :list_original, {:array, :map}
    field :commanders, {:array, :string}, default: []
    field :finished_at, :utc_datetime

    belongs_to :deck, Deck
    has_many :steps, OptimizationStep, preload_order: [asc: :position]

    timestamps()
  end

  @doc "Builds a changeset for an optimization run."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(optimization, attrs) do
    optimization
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end
end
