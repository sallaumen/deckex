defmodule Deckex.Workers.ImportDeckWorker do
  @moduledoc """
  Imports a deck from a Moxfield URL off the request path.

  A block, a private deck or a bad URL are permanent conditions — retrying
  cannot fix them, and the user has a working alternative in the paste form — so
  they cancel. Only a transient failure retries.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Deckex.Decks

  @permanent [:moxfield_blocked, :moxfield_private, :moxfield_not_found, :empty_decklist]

  @doc "Enqueues an import for the given Moxfield URL."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(url) when is_binary(url) do
    %{url: url} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url}}) do
    case Decks.import_from_url(url) do
      {:ok, _deck} -> :ok
      {:error, %{code: code} = error} when code in @permanent -> {:cancel, error.message}
      {:error, error} -> {:error, error}
    end
  end
end
