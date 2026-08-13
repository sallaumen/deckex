defmodule Deckex.Cards.Name do
  @moduledoc """
  Card-name normalization.

  The same card reaches us written several ways: `Cultivate`,
  `Cultivate (M21) 177`, `Agadeem's Awakening`, and
  `Agadeem's Awakening // Agadeem, the Undercrypt` all mean one card.
  `normalize/1` collapses them into the single key stored in
  `cards.name_normalized`, so a decklist line and a Scryfall response resolve to
  the same row.

  Note the two spellings of the face separator: **Scryfall writes `A // B` while
  Moxfield exports `A / B`.** Both must collapse to the same key, or every
  double-faced card misses the catalogue lookup and is re-fetched on every
  import, forever.
  """

  # Combining diacritical marks, left behind by NFD decomposition.
  @combining_marks ~r/[\x{0300}-\x{036F}]/u

  # A trailing " (SET) 123" / " (SET)" printed by most decklist exporters.
  #
  # The collector number is NOT always digits: promos and variants suffix a
  # letter ("204p", "256a") and List printings carry the original set as a
  # prefix ("BBD-56", "USG-111"). A digits-only pattern leaves the set code
  # glued to the name, which then resolves to nothing.
  @set_code ~r/\s*\([^)]*\)\s*[\p{L}\p{N}\-★]*\s*$/u

  # The face separator, in either spelling. No real Magic card name contains a
  # slash for any other reason.
  @face_separator ~r{\s*/+\s*}

  @doc """
  Normalizes a card name to its lookup key: front face only, no set code or
  collector number, accent-stripped, downcased, trimmed.

      iex> Deckex.Cards.Name.normalize("Agadeem's Awakening // Agadeem, the Undercrypt")
      "agadeem's awakening"

      iex> Deckex.Cards.Name.normalize("Cultivate (M21) 177")
      "cultivate"

      iex> Deckex.Cards.Name.normalize("Silundi Vision / Silundi Isle (ZNR) 80")
      "silundi vision"
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(name) when is_binary(name) do
    name
    |> display()
    |> strip_accents()
    |> String.downcase()
  end

  @doc """
  The card's real name, as Scryfall spells it: front face only, set code and
  collector number removed, **case and accents preserved**.

  This is what goes to the API. `normalize/1` is for our own lookup key and is
  lossy on purpose — sending it to Scryfall would ask for "juzam djinn", which
  is not a card.

      iex> Deckex.Cards.Name.display("Birgi, God of Storytelling / Harnfel, Horn of Bounty (KHM) 123")
      "Birgi, God of Storytelling"

      iex> Deckex.Cards.Name.display("Juzám Djinn")
      "Juzám Djinn"
  """
  @spec display(String.t()) :: String.t()
  def display(name) when is_binary(name) do
    name
    |> front_face()
    |> String.replace(@set_code, "")
    |> String.trim()
  end

  defp front_face(name), do: name |> String.split(@face_separator) |> hd()

  defp strip_accents(name) do
    name
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(@combining_marks, "")
  end
end
