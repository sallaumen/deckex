defmodule Deckex.Cards.Name do
  @moduledoc """
  Card-name normalization.

  The same card reaches us written several ways: `Cultivate`,
  `Cultivate (M21) 177`, `Agadeem's Awakening`, and
  `Agadeem's Awakening // Agadeem, the Undercrypt` all mean one card.
  `normalize/1` collapses them into the single key stored in
  `cards.name_normalized`, so a decklist line and a Scryfall response resolve to
  the same row.
  """

  # Combining diacritical marks, left behind by NFD decomposition.
  @combining_marks ~r/[\x{0300}-\x{036F}]/u

  # A trailing " (SET) 123" / " (SET)" printed by most decklist exporters.
  @set_code ~r/\s*\([^)]*\)\s*\d*\s*$/

  @doc """
  Normalizes a card name to its lookup key: front face only, no set code or
  collector number, accent-stripped, downcased, trimmed.

      iex> Deckex.Cards.Name.normalize("Agadeem's Awakening // Agadeem, the Undercrypt")
      "agadeem's awakening"

      iex> Deckex.Cards.Name.normalize("Cultivate (M21) 177")
      "cultivate"
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(name) when is_binary(name) do
    name
    |> front_face()
    |> String.replace(@set_code, "")
    |> strip_accents()
    |> String.downcase()
    |> String.trim()
  end

  defp front_face(name), do: name |> String.split("//") |> hd()

  defp strip_accents(name) do
    name
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(@combining_marks, "")
  end
end
