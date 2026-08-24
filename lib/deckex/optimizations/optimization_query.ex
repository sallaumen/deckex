defmodule Deckex.Optimizations.OptimizationQuery do
  @moduledoc """
  All reads over optimizations and their steps.

  The triad rule: contexts mutate, query modules read, edges do neither.
  """

  import Ecto.Query

  alias Deckex.Optimizations.Mark
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
      optimization -> Repo.preload(optimization, steps: :consult)
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
        where: o.deck_id == ^deck_id and o.status in [:running, :awaiting_choice, :paused],
        limit: 1
    )
  end

  @doc """
  Every deck that has a run in flight, as `deck_id => optimization`.

  One query for the whole table: A Mesa draws a dozen tiles and asking per
  tile would be a dozen round trips for a chip.
  """
  @spec live_by_deck() :: %{String.t() => Optimization.t()}
  def live_by_deck do
    Repo.all(
      from o in Optimization,
        where: o.status in [:running, :awaiting_choice, :paused],
        order_by: [desc: o.inserted_at],
        # Steps come along: A Mesa draws a progress bar per run, and a bar
        # needs to know how many stages there are and how many are done.
        preload: :steps
    )
    |> Map.new(&{&1.deck_id, &1})
  end

  @doc "Every card the owner flagged in a run, in the order they were flagged."
  @spec marks_for(String.t()) :: [Mark.t()]
  def marks_for(optimization_id) do
    Repo.all(
      from m in Mark,
        where: m.optimization_id == ^optimization_id,
        order_by: [asc: m.inserted_at]
    )
  end

  @doc "The step that owns a consult, with its optimization."
  @spec step_for_consult(String.t()) :: OptimizationStep.t() | nil
  def step_for_consult(consult_id) do
    Repo.one(
      from s in OptimizationStep,
        where: s.consult_id == ^consult_id,
        preload: [optimization: [steps: :consult]]
    )
  end

  @doc "One step by id, with its optimization and siblings."
  @spec get_step(String.t()) :: OptimizationStep.t() | nil
  def get_step(id) do
    OptimizationStep
    |> Repo.get(id)
    |> case do
      nil -> nil
      step -> Repo.preload(step, optimization: [steps: :consult])
    end
  end
end
