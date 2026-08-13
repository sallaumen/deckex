defmodule Deckex.Analysis.CardEntry do
  @moduledoc """
  One card in a deck, as the lenses see it: the card, how many copies, and the
  roles already classified for it.

  The type predicates here read the **front face**. A modal double-faced card
  whose back is a land is a spell you can also play as a land, and only the mana
  lens cares about the back — `mdfc_land?/1` is how it asks.
  """

  alias Deckex.Cards.Card

  @type t :: %__MODULE__{card: Card.t(), quantity: pos_integer(), roles: MapSet.t(atom())}

  @enforce_keys [:card, :quantity, :roles]
  defstruct [:card, :quantity, :roles]

  @pip_symbols ~w(W U B R G)

  @spec new(Card.t(), pos_integer(), Enumerable.t()) :: t()
  def new(%Card{} = card, quantity, roles) do
    %__MODULE__{card: card, quantity: quantity, roles: MapSet.new(roles)}
  end

  @spec cmc(t()) :: float()
  def cmc(%__MODULE__{card: %{cmc: nil}}), do: 0.0
  def cmc(%__MODULE__{card: %{cmc: cmc}}), do: Decimal.to_float(cmc)

  @spec front_type(t()) :: String.t()
  def front_type(%__MODULE__{card: card}) do
    card.type_line |> String.split("//") |> hd() |> String.trim()
  end

  @spec back_type(t()) :: String.t()
  def back_type(%__MODULE__{card: card}) do
    case String.split(card.type_line, "//") do
      [_front, back] -> String.trim(back)
      _single_faced -> ""
    end
  end

  @spec land?(t()) :: boolean()
  def land?(entry), do: String.contains?(front_type(entry), "Land")

  @doc "A spell whose back face is a land — worth half a land to the mana base."
  @spec mdfc_land?(t()) :: boolean()
  def mdfc_land?(entry), do: not land?(entry) and String.contains?(back_type(entry), "Land")

  @spec instant?(t()) :: boolean()
  def instant?(entry), do: String.contains?(front_type(entry), "Instant")

  @spec has_role?(t(), atom()) :: boolean()
  def has_role?(%__MODULE__{roles: roles}, kind), do: MapSet.member?(roles, kind)

  @doc """
  How many pips of `colour` the mana cost demands. `{X}{B}{B}{B}` is three black
  pips — the number that decides how many black sources the deck needs.
  """
  @spec pips(t(), String.t()) :: non_neg_integer()
  def pips(%__MODULE__{card: %{mana_cost: nil}}, _colour), do: 0

  def pips(%__MODULE__{card: %{mana_cost: cost}}, colour) when colour in @pip_symbols do
    cost |> String.graphemes() |> Enum.count(&(&1 == colour))
  end
end
