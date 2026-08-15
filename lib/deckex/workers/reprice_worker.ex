defmodule Deckex.Workers.RepriceWorker do
  @moduledoc """
  Prices cards from their cheapest printing, off the request path.

  Queue `:scryfall` runs one job at a time, and that is the point: this is the
  only work in the app that costs a request *per card* instead of per
  seventy-five, so it queues behind itself rather than racing an import for the
  same budget.

  Failure is per card, inside `Deckex.Cards.reprice_all/1` — a price is
  advisory, and a job that retried the whole batch because one card 404'd would
  spend the budget on the hundred cards that already worked.
  """
  use Oban.Worker, queue: :scryfall, max_attempts: 3

  alias Deckex.Cards

  @doc "Enqueues repricing for the given card ids."
  @spec enqueue([String.t()]) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(card_ids) when is_list(card_ids) do
    %{card_ids: card_ids} |> new() |> Oban.insert()
  end

  @doc """
  Enqueues repricing for the whole catalogue.

  What the owner reaches for after learning that the number on screen was the
  price of one arbitrary printing.
  """
  @spec enqueue_all() :: {:ok, non_neg_integer()} | {:error, term()}
  def enqueue_all do
    ids = Cards.list_all() |> Enum.map(& &1.id)

    case ids do
      [] -> {:ok, 0}
      ids -> with {:ok, _job} <- enqueue(ids), do: {:ok, length(ids)}
    end
  end

  @doc """
  Enqueues a sweep of everything whose price has gone stale.

  What the daily cron runs. After the catalogue has been swept once this is
  almost always a handful of cards or none at all, which is the point: a full
  reprice costs one request per card, and prices do not move fast enough to
  pay that every day.
  """
  @spec enqueue_stale() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_stale, do: %{stale: true} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stale" => true}}) do
    case Cards.stale_prices() do
      [] -> {:ok, %{checked: 0, changed: 0}}
      cards -> reprice(cards)
    end
  end

  def perform(%Oban.Job{args: %{"card_ids" => card_ids}}) do
    case Cards.list_by_ids(card_ids) do
      [] -> {:cancel, "nenhuma carta encontrada"}
      cards -> reprice(cards)
    end
  end

  defp reprice(cards) do
    %{checked: checked, changed: changed} = Cards.reprice_all(cards)

    {:ok, %{checked: checked, changed: length(changed)}}
  end
end
