defmodule Deckex.AI.Client do
  @moduledoc """
  Port for an LLM that returns structured, JSON-schema-constrained output. The
  real adapter is `Deckex.AI.ClaudeCli`; tests use `Deckex.AI.Mock`. Callers go
  through the `Deckex.AI` facade rather than naming an adapter directly.
  """

  @callback complete(prompt :: String.t(), schema :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, Deckex.Error.t()}
end
