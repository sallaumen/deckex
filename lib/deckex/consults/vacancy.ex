defmodule Deckex.Consults.Vacancy do
  @moduledoc """
  One decision on the Bancada: a need, and the cards that would answer it.

  The need is the load-bearing half. Refusing `Arcane Signet` is a judgement
  about a card; refusing *"sua curva quer mais aceleração de 2 mana"* is a
  judgement about the deck, and only the second is a question the owner is
  better placed to answer than the model is.

  `key` is what a click sends back and what `optimization_steps.selections` is
  keyed on. It is the action plus the position in the answer — both frozen the
  moment the consult lands, so it stays valid for as long as the answer does.
  """

  alias Deckex.Consults.Vacancy.Candidate

  @type t :: %__MODULE__{
          key: String.t(),
          action: :cut | :add,
          index: non_neg_integer(),
          grupo: String.t(),
          vaga: String.t(),
          candidatos: [Candidate.t()],
          reserve?: boolean()
        }

  @enforce_keys [:key, :action, :index, :grupo, :vaga, :candidatos]
  defstruct [:key, :action, :index, :grupo, :vaga, :candidatos, reserve?: false]

  defmodule Candidate do
    @moduledoc """
    One card offered for one vacancy, joined to the catalogue.

    The model names the card and says why it and not its neighbour; the app
    prices it. The price law holds here exactly as it does everywhere else —
    the schema has no price field for the model to fill in the first place.
    """

    alias Deckex.Cards.Card

    @type t :: %__MODULE__{
            name: String.t(),
            porque: String.t(),
            card: Card.t() | nil,
            price_usd: Decimal.t() | nil,
            resolved?: boolean()
          }

    @enforce_keys [:name, :porque]
    defstruct [:name, :porque, :card, :price_usd, resolved?: false]
  end

  @doc "The key a selection is stored under. Action plus position, both frozen."
  @spec key(:cut | :add, non_neg_integer()) :: String.t()
  def key(action, index), do: "#{action}:#{index}"
end
