defmodule Deckex.Cards.CardRole do
  @moduledoc """
  One role a card plays, with where the verdict came from.

  `source` is what makes the numbers auditable: `:rule` came from a regex, `:ai`
  from a model, `:manual` from the user. A `:manual` role is permanent — the
  user's correction outranks every later pass, and it is the signal for
  improving the rules.
  """
  use Deckex.Schema

  import Ecto.Changeset

  alias Deckex.Cards.Card
  alias Deckex.Cards.RoleMatch

  @type t :: %__MODULE__{}

  schema "card_roles" do
    field :kind, Ecto.Enum, values: RoleMatch.kinds()
    field :confidence, Ecto.Enum, values: [:high, :medium, :low]
    field :source, Ecto.Enum, values: [:rule, :ai, :manual]
    field :evidence, :string

    belongs_to :card, Card

    timestamps()
  end

  @doc "Builds a changeset for a classified role."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:card_id, :kind, :confidence, :source, :evidence])
    |> validate_required([:card_id, :kind, :confidence, :source])
    |> foreign_key_constraint(:card_id)
    |> unique_constraint([:card_id, :kind])
  end
end
