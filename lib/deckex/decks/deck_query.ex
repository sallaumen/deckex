defmodule Deckex.Decks.DeckQuery do
  @moduledoc """
  All reads of decks. Every function ends in a `Repo` call and returns data,
  never an `Ecto.Query`.
  """

  import Ecto.Query

  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckCard
  alias Deckex.Error
  alias Deckex.Repo

  @doc "Lists live decks, newest first."
  @spec list_decks() :: [Deck.t()]
  def list_decks do
    Repo.all(from d in Deck, where: is_nil(d.archived_at), order_by: [desc: d.inserted_at])
  end

  @doc "Fetches a deck by id, or nil."
  @spec get_deck(String.t()) :: Deck.t() | nil
  def get_deck(id), do: Repo.get(Deck, id)

  @doc "Fetches a deck by id as a tagged tuple."
  @spec fetch_deck(String.t()) :: {:ok, Deck.t()} | {:error, Error.t()}
  def fetch_deck(id) do
    case get_deck(id) do
      nil -> {:error, Error.new(:deck_not_found, "Não achei esse deck.", %{id: id})}
      deck -> {:ok, deck}
    end
  end

  @doc "Fetches a deck by its Moxfield public id, or nil."
  @spec get_by_public_id(String.t()) :: Deck.t() | nil
  def get_by_public_id(public_id), do: Repo.get_by(Deck, moxfield_public_id: public_id)

  @doc "One card in a deck, on a board, or nil."
  @spec get_deck_card(Deck.t(), String.t(), atom()) :: DeckCard.t() | nil
  def get_deck_card(%Deck{id: deck_id}, card_id, board) do
    Repo.get_by(DeckCard, deck_id: deck_id, card_id: card_id, board: board)
  end

  @doc "Lists a deck's cards with the card preloaded."
  @spec list_deck_cards(Deck.t()) :: [DeckCard.t()]
  def list_deck_cards(%Deck{id: deck_id}) do
    Repo.all(from dc in DeckCard, where: dc.deck_id == ^deck_id, preload: [:card])
  end
end
