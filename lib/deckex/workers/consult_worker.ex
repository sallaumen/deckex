defmodule Deckex.Workers.ConsultWorker do
  @moduledoc """
  Runs one consult off the request path.

  A vanished consult is permanent (`:cancel`); an AI timeout is transient and
  retries. Anything else has already been recorded on the row, so the job does
  not need to retry to preserve it.
  """
  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Deckex.Consults

  @doc "Enqueues the AI call for a consult."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(consult_id) when is_binary(consult_id) do
    %{consult_id: consult_id} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"consult_id" => consult_id}}) do
    case Consults.fetch(consult_id) do
      {:ok, consult} -> run(consult)
      {:error, error} -> {:cancel, error.message}
    end
  end

  defp run(consult) do
    case Consults.run(consult) do
      {:ok, _done} -> :ok
      {:error, %{code: :ai_timeout} = error} -> {:error, error}
      {:error, error} -> {:cancel, error.message}
    end
  end
end
