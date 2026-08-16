defmodule Deckex.Optimizations.Mark do
  @moduledoc """
  A card the owner flagged during a run, and what he has to say about it.

  Marking is cheap and reversible on purpose: it happens while reading, at the
  speed of reading. The note comes later, at the end, when there is a list of
  everything that caught the eye and the run is no longer moving.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Optimizations.Optimization

  @fields ~w(optimization_id card_name action note)a
  @required ~w(optimization_id card_name)a

  @type t :: %__MODULE__{}

  schema "optimization_marks" do
    belongs_to :optimization, Optimization

    field :card_name, :string

    # What the pipeline had done to it when it was flagged: an add, a cut, or
    # a refusal. The same note means different things against each.
    field :action, Ecto.Enum, values: [:add, :cut, :rejected]
    field :note, :string

    timestamps()
  end

  @doc "Builds a changeset for a mark."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(mark, attrs) do
    mark
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> unique_constraint([:optimization_id, :card_name],
      name: :optimization_marks_optimization_id_card_name_index
    )
  end

  @doc "Whether this mark carries something for the model to read."
  @spec said?(t()) :: boolean()
  def said?(%__MODULE__{note: note}), do: is_binary(note) and String.trim(note) != ""
end
