defmodule Deckex.Moxfield.DeckMapper do
  @moduledoc """
  Translates a Moxfield deck payload into decklist text, which
  `Deckex.Decks.DecklistParser` then reads — one parser for both import paths
  rather than two code paths that can drift apart.

  > **Unverified against a live response.** The endpoint returns 403 to an
  > unapproved client (see `Deckex.Moxfield`), so this mapping is written
  > against the community-documented shape and pinned by a hand-written
  > fixture. The day a User-Agent is approved, capture a real response and
  > check this module against it before trusting a URL import.
  """

  alias Deckex.Error

  @boards %{"commanders" => "Commander", "mainboard" => "Deck", "maybeboard" => "Maybeboard"}

  @spec to_decklist(map()) ::
          {:ok, %{name: String.t(), decklist: String.t()}} | {:error, Error.t()}
  def to_decklist(%{"boards" => boards} = payload) when is_map(boards) do
    decklist =
      @boards
      |> Enum.map(fn {key, header} -> section(boards[key], header) end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    {:ok, %{name: payload["name"] || "Deck sem nome", decklist: decklist}}
  end

  def to_decklist(_payload) do
    {:error,
     Error.new(:moxfield_not_found, "A resposta do Moxfield não tinha as cartas do deck.", %{})}
  end

  defp section(%{"cards" => cards}, header) when is_map(cards) and map_size(cards) > 0 do
    lines =
      cards
      |> Map.values()
      |> Enum.map(&line/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    if lines == [], do: "", else: Enum.join([header | lines], "\n") <> "\n"
  end

  defp section(_board, _header), do: ""

  defp line(%{"quantity" => quantity, "card" => %{"name" => name}}), do: "#{quantity} #{name}"
  defp line(_card), do: nil
end
