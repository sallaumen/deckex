defmodule Deckex.Consults.Suggestion do
  @moduledoc """
  One row of a consult's answer, joined to a real card.

  `name` is what the model said; `card` is what the catalogue found for it, and
  it is `nil` when nothing matched. A suggestion that will not resolve is shown
  as unresolved rather than dropped: a model naming a card that does not exist
  is information about the model, and hiding it would hide that.
  """

  alias Deckex.Cards.Card

  @type action :: :cut | :add

  @type t :: %__MODULE__{
          action: action(),
          name: String.t(),
          reason: String.t(),
          addresses: String.t() | nil,
          replaces: String.t() | nil,
          card: Card.t() | nil,
          price_usd: Decimal.t() | nil,
          resolved?: boolean()
        }

  @enforce_keys [:action, :name, :reason]
  defstruct [:action, :name, :reason, :addresses, :replaces, :card, :price_usd, resolved?: false]
end
