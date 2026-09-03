defmodule Deckex.Workers.ComboWorker do
  @moduledoc """
  Refreshes a deck's combos in the background.

  **Debounced, deliberately.** Every card added or removed changes what the
  deck assembles, and somebody editing five cards in a row would otherwise
  fire five requests at a public API that owes this app nothing. Oban's
  uniqueness collapses them into one job per deck per minute, which is manners
  and also correct: only the last list matters.

  A failure keeps whatever the deck already had. A combo list from yesterday
  describes the deck better than an empty one, and the deck stays flagged so
  the next edit tries again.
  """
  use Oban.Worker,
    queue: :scryfall,
    max_attempts: 3,
    unique: [period: 60, states: :incomplete, keys: [:deck_id]]

  alias Deckex.Combos
  alias Deckex.Decks
  alias Deckex.Log

  require Logger

  @doc "Schedules a refresh, collapsing a burst of edits into one request."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(deck_id) when is_binary(deck_id) do
    %{deck_id: deck_id} |> new(schedule_in: 30) |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"deck_id" => deck_id}}) do
    case Decks.fetch_deck(deck_id) do
      {:ok, deck} ->
        Log.context(deck: deck)

        refresh(deck)

      {:error, _gone} ->
        :ok
    end
  end

  defp refresh(deck) do
    case Combos.refresh(deck) do
      {:ok, _deck} ->
        :ok

      {:error, error} ->
        # The deck keeps yesterday's combos and stays flagged, so this is a
        # warning and not an error: nothing was lost and the next edit retries.
        Logger.warning("combos não atualizados: #{error.message}")

        {:error, error.message}
    end
  end
end
