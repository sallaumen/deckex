defmodule Deckex.AI.Usage do
  @moduledoc """
  What one call to the model actually cost, as the CLI reported it.

  Four token counters, not one. Cache reads are the bulk of every call this
  app makes — the briefing repeats the same deck, the same baselines and the
  same rules on every stage — and counting them together with fresh input
  would make a ten-stage run look like it read a novel each time. Kept apart,
  the number says what it is: mostly cache.

  Every field is measured. There is no estimator here, and there will not be:
  a token count someone guessed is worse than no token count, because it looks
  the same on screen.
  """

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cost_usd: Decimal.t(),
          duration_ms: non_neg_integer() | nil
        }

  defstruct input_tokens: 0,
            output_tokens: 0,
            cache_creation_tokens: 0,
            cache_read_tokens: 0,
            cost_usd: Decimal.new(0),
            duration_ms: nil

  @doc """
  Reads the `claude --output-format json` envelope.

  An envelope without `usage` — a stub, an older CLI, an error shape — gives
  an empty usage rather than an invented one.
  """
  @spec from_envelope(map()) :: t()
  def from_envelope(%{"usage" => usage} = envelope) when is_map(usage) do
    %__MODULE__{
      input_tokens: count(usage["input_tokens"]),
      output_tokens: count(usage["output_tokens"]),
      cache_creation_tokens: count(usage["cache_creation_input_tokens"]),
      cache_read_tokens: count(usage["cache_read_input_tokens"]),
      cost_usd: money(envelope["total_cost_usd"]),
      duration_ms: envelope["duration_ms"]
    }
  end

  def from_envelope(_no_usage), do: %__MODULE__{}

  @doc """
  Normalises whatever an adapter answered into `{:ok, output, usage}`.

  Two success shapes reach here because two kinds of adapter do. The real one
  reads `usage` out of the CLI envelope; a test double says nothing about
  tokens and gets an empty usage — measured or absent, never guessed. A double
  carrying invented counts would put fiction in the ledger, which reads exactly
  like a fact.
  """
  @spec attach(term()) :: {:ok, map(), t()} | {:error, term()}
  def attach({:ok, output, %__MODULE__{} = usage}), do: {:ok, output, usage}
  def attach({:ok, output}) when is_map(output), do: {:ok, output, %__MODULE__{}}
  def attach({:error, _reason} = error), do: error

  @doc "Every token the call touched, cache included."
  @spec total_tokens(t()) :: non_neg_integer()
  def total_tokens(%__MODULE__{} = usage) do
    usage.input_tokens + usage.output_tokens + usage.cache_creation_tokens +
      usage.cache_read_tokens
  end

  @doc "Whether the call reported anything at all."
  @spec measured?(t()) :: boolean()
  def measured?(%__MODULE__{} = usage), do: total_tokens(usage) > 0

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_missing), do: 0

  defp money(value) when is_float(value), do: value |> Decimal.from_float() |> Decimal.round(6)
  defp money(value) when is_integer(value), do: Decimal.new(value)
  defp money(_missing), do: Decimal.new(0)
end
