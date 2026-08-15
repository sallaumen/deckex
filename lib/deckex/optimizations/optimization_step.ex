defmodule Deckex.Optimizations.OptimizationStep do
  @moduledoc """
  One stage of one optimization run.

  `list_before` is the sandbox as this stage received it; the list it produces
  is **derived** — `Optimizations.list_after/1` applies `applied` to
  `list_before` — never stored, so there is exactly one source of truth.

  `applied` and `rejected` both carry the model's reason; `rejected` adds the
  engine's `"problems"`. A rejection is not a failure: it is the audit doing
  its job, and the timeline shows it as such.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Consults.Consult
  alias Deckex.Optimizations.Optimization

  @fields ~w(optimization_id position kind lens label status model consult_id
             list_before applied rejected feedback)a
  @required ~w(optimization_id position kind lens label status)a

  @type t :: %__MODULE__{}

  schema "optimization_steps" do
    field :position, :integer
    field :kind, Ecto.Enum, values: [:lens, :checkpoint, :validation, :reconstruction, :balance]
    field :lens, :string
    field :label, :string
    field :status, Ecto.Enum, values: [:pending, :running, :done, :skipped, :failed]
    # Null means "whatever the contract says". A value here is the owner having
    # redone this one stage with a different model.
    field :model, :string
    field :list_before, {:array, :map}
    field :applied, {:array, :map}, default: []
    field :rejected, {:array, :map}, default: []
    field :feedback, :map, default: %{}

    belongs_to :optimization, Optimization
    belongs_to :consult, Consult

    timestamps()
  end

  @doc "Builds a changeset for a stage."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(step, attrs) do
    step
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> unique_constraint([:optimization_id, :position])
  end
end
