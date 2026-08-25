defmodule Deckex.Consults.Consult do
  @moduledoc """
  One question put to the AI about one deck.

  The row stores the **exact briefing sent** and the **report it was built
  from**. That is what makes a consult reproducible — and it is also why "copy
  this prompt to your own terminal" costs nothing extra: the prompt is already
  here.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Decks.Deck

  @lenses [
    :speed_curve,
    :mana_ramp,
    :interaction,
    :consistency,
    :full,
    :finding,
    :matchup,
    :budget,
    :upgrade,
    :scout,
    :bracket,
    :visao,
    :balanco,
    :revisao,
    :livre,
    :pilares,
    :plano,
    :execucao,
    :critico
  ]

  @type t :: %__MODULE__{}

  schema "consults" do
    field :lens, Ecto.Enum, values: @lenses
    field :finding_code, :string
    field :status, Ecto.Enum, values: [:pending, :running, :done, :failed]
    field :briefing, :string
    field :report_snapshot, :map
    field :response, :map
    field :model, :string
    field :error, :string
    field :duration_ms, :integer

    # Set when this consult is a stage of an optimization run. A plain column,
    # not an assoc: the step owns the relationship (steps.consult_id); this is
    # the tag the deck page filters on.
    field :optimization_id, Ecto.UUID

    belongs_to :deck, Deck

    timestamps()
  end

  @doc "Every lens a consult can be scoped to."
  @spec lenses() :: [atom()]
  def lenses, do: @lenses

  @doc "Builds a changeset for a consult."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(consult, attrs) do
    consult
    |> cast(attrs, [
      :deck_id,
      :lens,
      :finding_code,
      :status,
      :briefing,
      :report_snapshot,
      :response,
      :model,
      :error,
      :duration_ms,
      :optimization_id
    ])
    |> validate_required([:deck_id, :lens, :status, :briefing, :report_snapshot])
    |> foreign_key_constraint(:deck_id)
  end
end
