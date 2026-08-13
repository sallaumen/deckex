defmodule Deckex.Events do
  @moduledoc """
  PubSub topics and payloads, in one place.

  Import is a multi-stage pipeline, so the deck screen renders each stage as it
  lands rather than blocking on a spinner. Changing a payload starts here.
  """

  alias Deckex.Decks.Deck

  @pubsub Deckex.PubSub

  @typedoc "Broadcast when any part of a deck changes."
  @type deck_updated :: {:deck_updated, deck_id :: String.t()}

  @doc "Subscribes the calling process to one deck's updates."
  @spec subscribe_deck(String.t()) :: :ok | {:error, term()}
  def subscribe_deck(deck_id), do: Phoenix.PubSub.subscribe(@pubsub, deck_topic(deck_id))

  @doc "Announces that a deck changed."
  @spec broadcast_deck_updated(Deck.t()) :: :ok | {:error, term()}
  def broadcast_deck_updated(%Deck{id: deck_id}) do
    Phoenix.PubSub.broadcast(@pubsub, deck_topic(deck_id), {:deck_updated, deck_id})
  end

  defp deck_topic(deck_id), do: "deck:#{deck_id}"
end
