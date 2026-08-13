defmodule Deckex.AI do
  @moduledoc """
  The single AI entry point. Resolves the configured adapter and applies the
  configured model so callers never name either.
  """

  @adapter Application.compile_env(:deckex, [Deckex.AI.Client, :adapter], Deckex.AI.ClaudeCli)

  @doc "Calls the AI client with the model default applied."
  @spec complete(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Deckex.Error.t()}
  def complete(prompt, schema, opts \\ []) do
    @adapter.complete(prompt, schema, Keyword.put_new(opts, :model, model()))
  end

  @doc ~S"""
  Configured model (default `"sonnet"`).
  """
  @spec model() :: String.t()
  def model, do: config(:model, "sonnet")

  @doc "How many cards go to the model in one classification call (default 15)."
  @spec batch_size() :: pos_integer()
  def batch_size, do: config(:batch_size, 15)

  defp config(key, default),
    do: :deckex |> Application.get_env(Deckex.AI, []) |> Keyword.get(key, default)
end
