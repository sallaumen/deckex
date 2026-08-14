defmodule Deckex.Consults.Vision do
  @moduledoc """
  One direction a `:visao` consult proposed, with the app's own numbers on it.

  The model names cards; the app prices them. `total_usd` is summed from the
  catalogue and never read from the answer — the price law holds here as
  everywhere else.
  """

  alias Deckex.Cards.Card

  @type card_row :: %{name: String.t(), card: Card.t() | nil, price_usd: Decimal.t() | nil}

  @type t :: %__MODULE__{
          nome: String.t(),
          eixo: String.t(),
          tese: String.t(),
          custo: String.t(),
          cartas: [card_row()],
          total_usd: Decimal.t(),
          comandante: Card.t() | nil,
          comandante_nome: String.t() | nil,
          comandante_problem: String.t() | nil
        }

  defstruct nome: "",
            eixo: "",
            tese: "",
            custo: "",
            cartas: [],
            total_usd: Decimal.new(0),
            comandante: nil,
            comandante_nome: nil,
            comandante_problem: nil
end
