defmodule Deckex.Factory do
  @moduledoc "ExMachina factories. See https://hexdocs.pm/ex_machina."
  use ExMachina.Ecto, repo: Deckex.Repo

  alias Deckex.Cards.Card
  alias Deckex.Cards.Name
  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckCard

  def card_factory do
    name = sequence(:card_name, &"Test Card #{&1}")

    %Card{
      oracle_id: Ecto.UUID.generate(),
      scryfall_id: Ecto.UUID.generate(),
      name: name,
      name_normalized: Name.normalize(name),
      mana_cost: "{2}{G}",
      cmc: Decimal.new("3.0"),
      type_line: "Sorcery",
      oracle_text: "Draw a card.",
      colors: ["G"],
      color_identity: ["G"],
      produced_mana: [],
      keywords: [],
      layout: "normal",
      card_faces: [],
      commander_legal: true,
      fetched_at: DateTime.utc_now(:second)
    }
  end

  def deck_factory do
    %Deck{
      name: sequence(:deck_name, &"Deck #{&1}"),
      source: :paste,
      status: :ready,
      color_identity: [],
      raw_decklist: "1 Sol Ring"
    }
  end

  def deck_card_factory do
    %DeckCard{
      deck: build(:deck),
      card: build(:card),
      quantity: 1,
      board: :main
    }
  end
end
