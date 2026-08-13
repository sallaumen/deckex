defmodule Deckex.AnalysisFixture do
  @moduledoc """
  Builds `CardEntry` and `DeckSnapshot` structs directly, with no database.

  The lenses are pure, so their tests should be too: a curve test that needs
  Postgres running is a test nobody runs.
  """

  alias Deckex.Analysis.CardEntry
  alias Deckex.Analysis.DeckSnapshot
  alias Deckex.Cards.Card

  @doc """
  A card entry. Every field has a neutral default, so a test sets only what it
  is about.
  """
  @spec entry(keyword()) :: CardEntry.t()
  def entry(attrs \\ []) do
    card = %Card{
      id: Keyword.get(attrs, :id, Ecto.UUID.generate()),
      name: Keyword.get(attrs, :name, "Carta"),
      mana_cost: Keyword.get(attrs, :mana_cost, "{2}"),
      cmc: attrs |> Keyword.get(:cmc, "2.0") |> Decimal.new(),
      type_line: Keyword.get(attrs, :type_line, "Artifact"),
      oracle_text: Keyword.get(attrs, :oracle_text, ""),
      color_identity: Keyword.get(attrs, :color_identity, []),
      produced_mana: Keyword.get(attrs, :produced_mana, [])
    }

    CardEntry.new(card, Keyword.get(attrs, :quantity, 1), Keyword.get(attrs, :roles, []))
  end

  @doc "A snapshot around the given main-deck entries."
  @spec snapshot([CardEntry.t()], keyword()) :: DeckSnapshot.t()
  def snapshot(main, opts \\ []) do
    %DeckSnapshot{
      deck_id: Keyword.get(opts, :deck_id, Ecto.UUID.generate()),
      deck_name: Keyword.get(opts, :deck_name, "Deck de teste"),
      color_identity: Keyword.get(opts, :color_identity, []),
      commanders: Keyword.get(opts, :commanders, []),
      main: main
    }
  end
end
