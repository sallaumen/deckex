defmodule Deckex.Events do
  @moduledoc """
  PubSub topics and payloads, in one place.

  Import is a multi-stage pipeline, so the deck screen renders each stage as it
  lands rather than blocking on a spinner. Changing a payload starts here.
  """

  alias Deckex.Consults.Consult
  alias Deckex.Decks.Deck
  alias Deckex.Optimizations.Optimization

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

  @typedoc "Broadcast when a consult changes state."
  @type consult_updated :: {:consult_updated, consult_id :: String.t()}

  @doc "Subscribes the calling process to one deck's consult activity."
  @spec subscribe_consults(String.t()) :: :ok | {:error, term()}
  def subscribe_consults(deck_id), do: Phoenix.PubSub.subscribe(@pubsub, consult_topic(deck_id))

  @doc "Announces that a consult changed."
  @spec broadcast_consult(Consult.t()) :: :ok | {:error, term()}
  def broadcast_consult(%Consult{deck_id: deck_id, id: id}) do
    Phoenix.PubSub.broadcast(@pubsub, consult_topic(deck_id), {:consult_updated, id})
  end

  @typedoc "Broadcast when an optimization run or any of its stages changes."
  @type optimization_updated :: {:optimization_updated, optimization_id :: String.t()}

  @doc "Subscribes the calling process to one optimization run."
  @spec subscribe_optimization(String.t()) :: :ok | {:error, term()}
  def subscribe_optimization(id), do: Phoenix.PubSub.subscribe(@pubsub, optimization_topic(id))

  @doc "Announces that an optimization run changed."
  @spec broadcast_optimization(Optimization.t()) :: :ok | {:error, term()}
  def broadcast_optimization(%Optimization{id: id}) do
    Phoenix.PubSub.broadcast(@pubsub, optimization_topic(id), {:optimization_updated, id})
  end

  defp optimization_topic(id), do: "optimization:#{id}"

  defp deck_topic(deck_id), do: "deck:#{deck_id}"
  defp consult_topic(deck_id), do: "deck:#{deck_id}:consults"
end
