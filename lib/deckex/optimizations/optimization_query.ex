defmodule Deckex.Optimizations.OptimizationQuery do
  @moduledoc """
  All reads over optimizations and their steps.

  The triad rule: contexts mutate, query modules read, edges do neither.
  """

  import Ecto.Query

  alias Deckex.Optimizations.Optimization
  alias Deckex.Optimizations.OptimizationStep
  alias Deckex.Repo

  @doc "One run with its steps, ordered by position."
  @spec get(String.t()) :: Optimization.t() | nil
  def get(id) do
    Optimization
    |> Repo.get(id)
    |> case do
      nil -> nil
      optimization -> Repo.preload(optimization, :steps)
    end
  end

  @doc "Every run for a deck, newest first, steps preloaded."
  @spec list_for_deck(String.t()) :: [Optimization.t()]
  def list_for_deck(deck_id) do
    Repo.all(
      from o in Optimization,
        where: o.deck_id == ^deck_id,
        order_by: [desc: o.inserted_at],
        preload: :steps
    )
  end

  @doc "The run currently holding this deck's sandbox, if any."
  @spec running_for_deck(String.t()) :: Optimization.t() | nil
  def running_for_deck(deck_id) do
    Repo.one(
      from o in Optimization,
        where: o.deck_id == ^deck_id and o.status in [:running, :paused],
        limit: 1
    )
  end

  @doc "The step that owns a consult, with its optimization."
  @spec step_for_consult(String.t()) :: OptimizationStep.t() | nil
  def step_for_consult(consult_id) do
    Repo.one(
      from s in OptimizationStep,
        where: s.consult_id == ^consult_id,
        preload: [optimization: :steps]
    )
  end

  @doc "One step by id, with its optimization and siblings."
  @spec get_step(String.t()) :: OptimizationStep.t() | nil
  def get_step(id) do
    OptimizationStep
    |> Repo.get(id)
    |> case do
      nil -> nil
      step -> Repo.preload(step, optimization: :steps)
    end
  end
end
