defmodule Deckex.Optimizations do
  @moduledoc """
  The Otimizador: a pipeline of AI stages over a sandbox copy of a deck.

  Each stage consults a model through one lens, the engine audits the answer,
  and the clean changes are applied automatically — **to the sandbox, never to
  the real deck**. Later stages see everything earlier stages did and may
  revert it once, with a reason; the audit's flip-flop guard stops churn.

  See `docs/superpowers/specs/2026-08-14-otimizador-design.md`.
  """

  alias Deckex.Optimizations.OptimizationQuery

  defdelegate fetch_run(id), to: __MODULE__, as: :fetch

  @doc "One run with its steps, or a not-found error."
  @spec fetch(String.t()) ::
          {:ok, Deckex.Optimizations.Optimization.t()} | {:error, Deckex.Error.t()}
  def fetch(id) do
    case OptimizationQuery.get(id) do
      nil -> {:error, Deckex.Error.new(:optimization_not_found, "Não achei essa otimização.")}
      optimization -> {:ok, optimization}
    end
  end

  defdelegate list_for_deck(deck_id), to: OptimizationQuery
end
