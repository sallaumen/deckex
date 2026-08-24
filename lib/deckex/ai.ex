defmodule Deckex.AI do
  @moduledoc """
  The single AI entry point. Resolves the configured adapter and applies the
  configured model so callers never name either.
  """

  alias Deckex.AI.Usage

  @adapter Application.compile_env(:deckex, [Deckex.AI.Client, :adapter], Deckex.AI.ClaudeCli)

  @doc """
  Calls the AI client with the model default applied, and normalises the
  answer to `{:ok, output, usage}`.

  An adapter that reports no usage gets an empty one — measured or absent,
  never guessed.
  """
  @spec complete(String.t(), map(), keyword()) ::
          {:ok, map(), Usage.t()} | {:error, Deckex.Error.t()}
  def complete(prompt, schema, opts \\ []) do
    prompt
    |> @adapter.complete(schema, Keyword.put_new(opts, :model, model()))
    |> Usage.attach()
  end

  @doc ~S"""
  The model to ask: the stored setting, falling back to config (default
  `"sonnet"`).
  """
  @spec model() :: String.t()
  def model, do: Deckex.Settings.get(:claude_model) || config(:model, "sonnet")

  @doc "How many cards go to the model in one classification call (default 15)."
  @spec batch_size() :: pos_integer()
  def batch_size, do: config(:batch_size, 15)

  defp config(key, default),
    do: :deckex |> Application.get_env(Deckex.AI, []) |> Keyword.get(key, default)
end
