defmodule Deckex.AI.Client do
  @moduledoc """
  Port for an LLM that returns structured, JSON-schema-constrained output. The
  real adapter is `Deckex.AI.ClaudeCli`; tests use `Deckex.AI.Mock`. Callers go
  through the `Deckex.AI` facade rather than naming an adapter directly.
  """

  @doc """
  Answers with the structured output and, when the adapter can measure it,
  what the call cost.

  Two success shapes on purpose. The real adapter reads `usage` out of the CLI
  envelope and returns the three-tuple; a test double that says nothing about
  tokens returns the pair, and the facade fills in an empty usage rather than
  inventing numbers for it. A mock carrying made-up token counts would put
  fiction in the ledger, which is worse than a gap.
  """
  @callback complete(prompt :: String.t(), schema :: map(), opts :: keyword()) ::
              {:ok, map()} | {:ok, map(), Deckex.AI.Usage.t()} | {:error, Deckex.Error.t()}
end
