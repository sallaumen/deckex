defmodule Deckex.AI.Call do
  @moduledoc """
  One recorded call to the model: what it was for, what it belonged to, and
  what it cost.

  A ledger row, not a counter — it is written once and never updated, so any
  total the app shows can be re-derived from the rows that produced it.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.AI.Usage
  alias Deckex.Consults.Consult
  alias Deckex.Decks.Deck

  @fields ~w(kind model deck_id consult_id input_tokens output_tokens
             cache_creation_tokens cache_read_tokens cost_usd duration_ms)a

  @type t :: %__MODULE__{}

  schema "ai_calls" do
    belongs_to :deck, Deck
    belongs_to :consult, Consult

    # `consult` is an answer about a deck; `classification` is the bulk role
    # pass over new cards, which belongs to no deck and costs money anyway.
    field :kind, Ecto.Enum, values: [:consult, :classification]
    field :model, :string

    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cache_creation_tokens, :integer, default: 0
    field :cache_read_tokens, :integer, default: 0
    field :cost_usd, :decimal, default: Decimal.new(0)
    field :duration_ms, :integer

    timestamps()
  end

  @doc "Builds a row from a usage struct plus what the call was for."
  @spec changeset(t(), Usage.t(), keyword()) :: Ecto.Changeset.t()
  def changeset(call, %Usage{} = usage, opts) do
    attrs =
      usage
      |> Map.take(~w(input_tokens output_tokens cache_creation_tokens cache_read_tokens
                     cost_usd duration_ms)a)
      |> Map.merge(%{
        kind: Keyword.fetch!(opts, :kind),
        model: Keyword.get(opts, :model),
        deck_id: Keyword.get(opts, :deck_id),
        consult_id: Keyword.get(opts, :consult_id)
      })

    call
    |> cast(attrs, @fields)
    |> validate_required([:kind])
  end
end
