defmodule Deckex.Workers.OptimizationAdvanceWorker do
  @moduledoc """
  Advances an optimization after one of its consults lands: audit the answer,
  apply the clean changes to the sandbox, and start the next stage.

  A separate job rather than inline in the consult's own worker, so a crash in
  the advance never loses the answer that was already paid for — the consult
  row is committed before this job exists.
  """
  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Deckex.Consults
  alias Deckex.Optimizations

  @doc "Enqueues the advance for a finished pipeline consult."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(consult_id) when is_binary(consult_id) do
    %{consult_id: consult_id} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"consult_id" => consult_id}}) do
    case Consults.fetch(consult_id) do
      {:ok, consult} -> Optimizations.advance(consult)
      {:error, error} -> {:cancel, error.message}
    end
  end
end
