defmodule Deckex.Workers.ClassifyCardsWorker do
  @moduledoc """
  Classifies a batch of cards off the request path. Args are ids, never structs.

  Error semantics follow the playbook: a card that has vanished is a permanent
  failure (`:cancel`), not something to retry; an AI timeout is transient and
  retries with backoff.
  """
  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Deckex.Cards

  @doc "Enqueues classification for the given card ids."
  @spec enqueue([String.t()]) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(card_ids) when is_list(card_ids) do
    %{card_ids: card_ids} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"card_ids" => card_ids}}) do
    case Cards.list_by_ids(card_ids) do
      [] -> {:cancel, "nenhuma carta encontrada"}
      cards -> classify(cards)
    end
  end

  defp classify(cards) do
    case Cards.classify_all(cards) do
      {:ok, _counts} -> :ok
      {:error, %{code: :ai_timeout} = error} -> {:error, error}
      {:error, error} -> {:cancel, error.message}
    end
  end
end
