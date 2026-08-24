defmodule Deckex.Workers.CatalogueWorker do
  @moduledoc """
  Fetches the cards a consult's answer names, after the attempt at answer time
  failed.

  The attempt inside `Deckex.Consults.run/1` is best-effort by design — a
  Scryfall outage must not cost an answer that already cost money. What was
  missing is what happens *next*: nothing did, so a card lost to one 503 stayed
  lost, the suggestion table said "não achei essa carta na Scryfall" about a
  card Scryfall has, and the audit and the optimizer dropped that suggestion
  from every count they make. Measured over ten days before this worker
  existed: five consults, ten real cards.

  Queue `:scryfall` at one job at a time, like `Deckex.Workers.RepriceWorker`,
  because both spend the same rate-limit budget. `max_attempts: 5` with Oban's
  backoff covers an outage of roughly half an hour; `unique` keeps a run of
  failing consults from queueing the same work twice.
  """
  use Oban.Worker,
    queue: :scryfall,
    max_attempts: 5,
    unique: [period: 300, states: :incomplete]

  alias Deckex.Consults

  @doc "Enqueues a catalogue refresh for one consult."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(consult_id) when is_binary(consult_id) do
    %{consult_id: consult_id} |> new() |> Oban.insert()
  end

  @doc """
  Enqueues a refresh for every consult whose answer names a card the catalogue
  is missing.

  What the owner reaches for after learning that a suggestion they never got to
  weigh was a real card all along. Consults whose catalogue is already complete
  are not queued at all, so clicking twice costs nothing.
  """
  @spec enqueue_all() :: {:ok, non_neg_integer()} | {:error, term()}
  def enqueue_all do
    Consults.incomplete_catalogue()
    |> Enum.reduce_while({:ok, 0}, fn consult, {:ok, queued} ->
      case enqueue(consult.id) do
        {:ok, _job} -> {:cont, {:ok, queued + 1}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"consult_id" => consult_id}}) do
    case Consults.fetch(consult_id) do
      # `refresh_catalogue/1` answers `:ok` or `{:error, _}`, which is exactly
      # what Oban reads: a Scryfall still down is retried, not discarded.
      {:ok, consult} -> Consults.refresh_catalogue(consult)
      {:error, error} -> {:cancel, error.message}
    end
  end
end
