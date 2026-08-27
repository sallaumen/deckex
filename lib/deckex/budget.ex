defmodule Deckex.Budget do
  @moduledoc """
  The shape of a deck's spending, in two tiers with room to break the rule.

  A single per-card ceiling answers one question — *is this card too
  expensive?* — and gets the real one wrong. The owner's actual constraint is
  about the **list**, not the card: he will happily own a few cards at four
  hundred reais and would rather not own twelve, and he wants exactly enough
  room for the two cards that are worth breaking his own rule for.

  So the policy is a count, not a line:

  - **Cara** — past `expensive_card_brl`. The deck may hold `expensive_card_max`
    of them.
  - **Exceção** — past the per-card ceiling. The deck may hold
    `exception_card_max` of them, and by the owner's decision there is nothing
    above that: the two slots *are* the roof. A four-thousand-real card can
    take one, and then it is spent.

  A card over the ceiling is over the expensive line too, so it occupies one of
  each. That is the intended reading — an exception is an expensive card that
  also broke the ceiling, not a separate species.

  Reads Settings, exactly like `Deckex.Money` does and for the same reason: the
  numbers are the owner's, and the alternative is threading four integers
  through every caller. `Deckex.Analysis` stays pure and never calls this.
  """

  alias Deckex.Analysis.CardEntry
  alias Deckex.Money
  alias Deckex.Settings

  @type tier :: :expensive | :exception
  @type policy :: %{
          expensive: %{threshold: pos_integer() | nil, max: non_neg_integer() | nil},
          exception: %{threshold: pos_integer() | nil, max: non_neg_integer() | nil}
        }
  @type occupancy :: %{expensive: non_neg_integer(), exception: non_neg_integer()}

  @doc """
  The two tiers as the owner has them configured.

  A `nil` threshold or `nil` max means that tier is switched off — zero in
  Ajustes reads as "no limit", the same convention the ceilings already use.
  """
  @spec policy() :: policy()
  def policy do
    %{
      expensive: %{
        threshold: positive(:expensive_card_brl),
        max: positive(:expensive_card_max)
      },
      exception: %{
        threshold: positive(:upgrade_max_brl),
        max: positive(:exception_card_max)
      }
    }
  end

  @doc """
  The policy an optimization froze into its contract, or today's if it has
  none.

  A run that started under one set of numbers must finish under them; a run
  from before this existed simply uses the current policy rather than none at
  all, which would silently drop the guard for exactly the old runs the owner
  is most likely to resume.
  """
  @spec from_contract(map() | nil) :: policy()
  def from_contract(nil), do: policy()

  def from_contract(shape) when is_map(shape) do
    %{
      expensive: %{threshold: shape["cara_brl"], max: shape["cara_max"]},
      exception: %{threshold: shape["excecao_brl"], max: shape["excecao_max"]}
    }
  end

  @doc "The policy as a contract stores it: string keys, no structs."
  @spec to_contract(policy()) :: map()
  def to_contract(policy) do
    %{
      "cara_brl" => policy.expensive.threshold,
      "cara_max" => policy.expensive.max,
      "excecao_brl" => policy.exception.threshold,
      "excecao_max" => policy.exception.max
    }
  end

  @doc """
  The same policy with both limits removed — the tiers still classify, nothing
  is ever refused for lack of room.

  The Bancada uses it to ask the per-card question on its own. The quota is a
  property of the whole answer, so charging forty candidates against it would
  refuse most of them for a limit none of them had reached; the real quota is
  applied to the cards he actually chose.
  """
  @spec unlimited(policy()) :: policy()
  def unlimited(policy) do
    %{
      expensive: %{policy.expensive | max: nil},
      exception: %{policy.exception | max: nil}
    }
  end

  @doc """
  How many cards of each tier `entries` already holds.

  Counts copies, not names: `quantity` is one for everything but basic lands,
  and a basic land is never near either line anyway.
  """
  @spec occupancy([CardEntry.t()], policy()) :: occupancy()
  def occupancy(entries, policy \\ policy()) do
    %{
      expensive: count_over(entries, policy.expensive.threshold),
      exception: count_over(entries, policy.exception.threshold)
    }
  end

  @doc """
  Which tier a price falls in, or `nil` when it is an ordinary card.

  An unpriced card is ordinary. Refusing a card because we do not know what it
  costs would be inventing a fact — the same rule the ceiling already follows.
  """
  @spec tier(Decimal.t() | nil, policy()) :: tier() | nil
  def tier(nil, _policy), do: nil

  def tier(price_usd, policy) do
    cond do
      over?(price_usd, policy.exception.threshold) -> :exception
      over?(price_usd, policy.expensive.threshold) -> :expensive
      true -> nil
    end
  end

  @doc """
  Whether one more card of `tier` still fits.

  `nil` max means the tier is switched off and everything fits.
  """
  @spec room?(occupancy(), tier() | nil, policy()) :: boolean()
  def room?(_occupancy, nil, _policy), do: true

  def room?(occupancy, tier, policy) do
    case policy[tier].max do
      nil -> true
      max -> occupancy[tier] < max
    end
  end

  @doc """
  Records one more card of `tier` against the occupancy, or one fewer when
  `delta` is negative.

  A run that cuts an expensive card and adds another has not changed the shape
  of the deck, and an engine that only ever counted upwards would say it had.
  """
  @spec charge(occupancy(), tier() | nil, -1 | 1) :: occupancy()
  def charge(occupancy, nil, _delta), do: occupancy

  # An exception is an expensive card that also broke the ceiling: it takes one
  # of each, or the ten-card limit would be quietly bypassed by the priciest
  # cards in the deck.
  def charge(occupancy, :exception, delta) do
    occupancy |> bump(:exception, delta) |> bump(:expensive, delta)
  end

  def charge(occupancy, :expensive, delta), do: bump(occupancy, :expensive, delta)

  defp bump(occupancy, tier, delta), do: Map.update!(occupancy, tier, &max(&1 + delta, 0))

  defp count_over(_entries, nil), do: 0

  defp count_over(entries, threshold) do
    Enum.reduce(entries, 0, fn %CardEntry{card: card, quantity: quantity}, total ->
      if over?(card.price_usd, threshold), do: total + quantity, else: total
    end)
  end

  defp over?(nil, _threshold), do: false
  defp over?(_price, nil), do: false

  defp over?(price_usd, threshold) do
    case Money.to_brl(price_usd) do
      nil -> false
      brl -> Decimal.gt?(brl, Decimal.new(threshold))
    end
  end

  # Zero is off, the convention every other number in Ajustes already uses.
  defp positive(key) do
    case Settings.get(key) do
      value when is_integer(value) and value > 0 -> value
      _off -> nil
    end
  end
end
