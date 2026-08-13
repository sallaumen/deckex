defmodule Deckex.Money do
  @moduledoc """
  Card prices, in the two currencies that matter here.

  Scryfall quotes in USD, and that is the number we store. The rate to reais is
  a **setting, not a live feed**: a background job chasing an FX API would be a
  new external dependency and a new failure mode, for a number whose job is to
  give a sense of scale. The rate is on screen in Ajustes, so what you are
  looking at is never a mystery.

  A card with no price prints an em dash. Printing `R$ 0,00` for "we do not
  know" would be a lie with a decimal point on it.
  """

  alias Deckex.Settings

  @unknown "—"

  @doc "The USD → BRL rate currently configured."
  @spec rate() :: float()
  def rate, do: Settings.get(:usd_to_brl)

  @doc "Converts a USD amount to BRL, or nil when the price is unknown."
  @spec to_brl(Decimal.t() | nil) :: Decimal.t() | nil
  def to_brl(nil), do: nil

  def to_brl(%Decimal{} = usd) do
    usd |> Decimal.mult(Decimal.from_float(rate())) |> Decimal.round(2)
  end

  @doc ~S"""
  Formats a USD amount, e.g. `"US$ 25,50"`.
  """
  @spec usd(Decimal.t() | nil) :: String.t()
  def usd(nil), do: @unknown
  def usd(%Decimal{} = amount), do: "US$ " <> format(amount)

  @doc ~S"""
  Formats a USD amount converted to reais, e.g. `"R$ 137,70"`.
  """
  @spec brl(Decimal.t() | nil) :: String.t()
  def brl(nil), do: @unknown
  def brl(%Decimal{} = usd), do: "R$ " <> format(to_brl(usd))

  # pt-BR: comma for the decimal separator.
  defp format(%Decimal{} = amount) do
    amount |> Decimal.round(2) |> Decimal.to_string(:normal) |> String.replace(".", ",")
  end
end
